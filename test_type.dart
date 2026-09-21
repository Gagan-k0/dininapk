void main() { 
  var rawItem = <dynamic, dynamic>{'a': 1}; 
  try { 
    var o = rawItem as Map<String, dynamic>; 
    print('Success'); 
  } catch(e) { 
    print(e); 
  } 
}
