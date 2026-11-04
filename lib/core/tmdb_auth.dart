/// TMDB supports either v4 Read Access Token or v3 API key.
/// The API key must only be placed on requests to the official TMDB origin.
class TmdbCredentials {
  const TmdbCredentials({required this.mode, required this.value});
  final String mode;
  final String value;
  bool get isConfigured =>
      value.trim().isNotEmpty && (mode == 'token' || mode == 'apiKey');
  Uri uri(String resource, Map<String, String> params) {
    if (!isConfigured) throw StateError('请先配置 TMDB 访问凭证');
    if (!resource.startsWith('/') || resource.startsWith('//')) {
      throw ArgumentError('非法 TMDB API 路径');
    }
    return Uri.parse('https://api.themoviedb.org/3$resource').replace(
      queryParameters: {
        ...params,
        if (mode == 'apiKey') 'api_key': value.trim(),
      },
    );
  }

  Map<String, String> get headers => {
    'Accept': 'application/json',
    if (mode == 'token') 'Authorization': 'Bearer ${value.trim()}',
  };
}
