/// Both accounts must resolve to the same direct-conversation storage key.
String directConversationId(String first, String second) {
  final a = first.trim().toLowerCase();
  final b = second.trim().toLowerCase();
  return a.compareTo(b) <= 0 ? 'dm:$a:$b' : 'dm:$b:$a';
}
