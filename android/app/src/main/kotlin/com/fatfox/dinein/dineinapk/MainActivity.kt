package com.fatfox.dinein.dineinapk

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/** Hosts the raw-ESC/POS USB printer channel used by lib/services/usb_printer.dart. */
class MainActivity : FlutterActivity() {
    private val usbWorker = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val usbManager: UsbManager
        get() = getSystemService(Context.USB_SERVICE) as UsbManager

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, USB_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "list" -> result.success(listPrinters())
                    "write" -> {
                        val vendorId = call.argument<Int>("vendorId")
                        val productId = call.argument<Int>("productId")
                        val bytes = call.argument<ByteArray>("bytes")
                        if (vendorId == null || productId == null || bytes == null) {
                            result.error("bad_args", "USB printer not selected.", null)
                        } else {
                            write(vendorId, productId, bytes, result)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        usbWorker.shutdown()
        super.onDestroy()
    }

    /**
     * First bulk-OUT endpoint on a printer-class interface, or on the
     * vendor-specific class that many cheap thermal printers report instead.
     */
    private fun printerOut(device: UsbDevice): Pair<UsbInterface, UsbEndpoint>? {
        for (i in 0 until device.interfaceCount) {
            val intf = device.getInterface(i)
            if (intf.interfaceClass != UsbConstants.USB_CLASS_PRINTER &&
                intf.interfaceClass != UsbConstants.USB_CLASS_VENDOR_SPEC
            ) continue
            for (e in 0 until intf.endpointCount) {
                val ep = intf.getEndpoint(e)
                if (ep.type == UsbConstants.USB_ENDPOINT_XFER_BULK &&
                    ep.direction == UsbConstants.USB_DIR_OUT
                ) return intf to ep
            }
        }
        return null
    }

    private fun listPrinters(): List<Map<String, Any?>> =
        usbManager.deviceList.values
            .filter { printerOut(it) != null }
            .distinctBy { it.vendorId to it.productId }
            .map {
                mapOf(
                    "vendorId" to it.vendorId,
                    "productId" to it.productId,
                    "name" to runCatching { it.productName }.getOrNull(),
                )
            }

    private fun write(vendorId: Int, productId: Int, bytes: ByteArray, result: MethodChannel.Result) {
        val device = usbManager.deviceList.values
            .firstOrNull { it.vendorId == vendorId && it.productId == productId }
        if (device == null) {
            result.error("not_found", "USB printer is not connected. Check the cable and try again.", null)
            return
        }
        if (usbManager.hasPermission(device)) {
            send(device, bytes, result)
            return
        }
        requestPermission(device) { granted ->
            if (granted) {
                send(device, bytes, result)
            } else {
                result.error(
                    "permission_denied",
                    "USB permission denied. Tap OK when Android asks to allow the printer.",
                    null,
                )
            }
        }
    }

    private fun requestPermission(device: UsbDevice, onResult: (Boolean) -> Unit) {
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                unregisterReceiver(this)
                onResult(intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false))
            }
        }
        val filter = IntentFilter(ACTION_USB_PERMISSION)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            registerReceiver(receiver, filter)
        }
        // Package-scoped so no other app can receive or forge the grant, and
        // mutable because UsbManager must attach EXTRA_PERMISSION_GRANTED.
        val intent = Intent(ACTION_USB_PERMISSION).setPackage(packageName)
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0
        usbManager.requestPermission(device, PendingIntent.getBroadcast(this, 0, intent, flags))
    }

    private fun send(device: UsbDevice, bytes: ByteArray, result: MethodChannel.Result) {
        usbWorker.execute {
            val error = transfer(device, bytes)
            mainHandler.post {
                if (error == null) result.success(true) else result.error("write_failed", error, null)
            }
        }
    }

    /** Returns null on success, else a message fit to show the waiter. */
    private fun transfer(device: UsbDevice, bytes: ByteArray): String? {
        val (intf, ep) = printerOut(device) ?: return "This USB device is not a printer."
        val connection = usbManager.openDevice(device)
            ?: return "Could not open the USB printer. Replug it and try again."
        try {
            if (!connection.claimInterface(intf, true)) {
                return "USB printer is busy. Replug it and try again."
            }
            var offset = 0
            while (offset < bytes.size) {
                val length = minOf(CHUNK_BYTES, bytes.size - offset)
                val sent = connection.bulkTransfer(ep, bytes, offset, length, TIMEOUT_MS)
                if (sent <= 0) return "USB printer stopped accepting data. Check paper and cable."
                offset += sent
            }
            return null
        } finally {
            connection.releaseInterface(intf)
            connection.close()
        }
    }

    companion object {
        private const val USB_CHANNEL = "com.fatfox.dinein/usb_printer"
        private const val ACTION_USB_PERMISSION = "com.fatfox.dinein.dineinapk.USB_PERMISSION"
        private const val CHUNK_BYTES = 4096
        private const val TIMEOUT_MS = 5000
    }
}
