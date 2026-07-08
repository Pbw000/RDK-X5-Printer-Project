/// Shared file-type icon resolver.
///
/// Used by home screen, queue screen, and file preview to map file
/// extensions to the corresponding asset icon path.
String fileIconForName(String name) {
  final ext = name.split('.').last.toLowerCase();
  return switch (ext) {
    'pdf' => 'assets/icons/pdf.webp',
    'txt' => 'assets/icons/txt.webp',
    'html' || 'htm' => 'assets/icons/html.webp',
    'js' => 'assets/icons/js.webp',
    'xml' => 'assets/icons/xml.webp',
    'md' || 'markdown' => 'assets/icons/markdown.webp',
    'webp' => 'assets/icons/webp.webp',
    'jpg' || 'jpeg' || 'png' || 'gif' || 'bmp' => 'assets/icons/image.webp',
    _ => 'assets/icons/txt.webp',
  };
}
