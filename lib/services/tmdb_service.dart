import 'dart:convert';
import 'package:http/http.dart' as http;
import '../constants.dart';

class TmdbService {
  static Future<Map<String, dynamic>> _get(String endpoint, {Map<String, String>? params}) async {
    // TMDB defaults adult titles off for search/lists; include NSFW / all certifications.
    final queryParams = {
      'api_key': TmdbApi.apiKey,
      'language': 'en-US',
      'include_adult': 'true',
      ...?params,
    };
    final uri = Uri.parse('${TmdbApi.baseUrl}$endpoint').replace(queryParameters: queryParams);
    final response = await http.get(uri, headers: {'accept': 'application/json'});
    if (response.statusCode == 200) {
      return json.decode(response.body) as Map<String, dynamic>;
    }
    throw Exception('Failed to load: ${response.statusCode}');
  }

  static Future<List<dynamic>> getTrending({String timeWindow = 'day'}) async {
    final data = await _get('/trending/all/$timeWindow');
    return data['results'] as List<dynamic>;
  }

  /// Same feed as PlayTorrioV2 mobile home (`/trending/movie/{window}`).
  static Future<List<dynamic>> getTrendingMovies({String timeWindow = 'day'}) async {
    final data = await _get('/trending/movie/$timeWindow');
    return data['results'] as List<dynamic>;
  }

  /// TV trending for parity with mobile-style browsing (not used on V2 home, but useful for TV tab).
  static Future<List<dynamic>> getTrendingTv({String timeWindow = 'day'}) async {
    final data = await _get('/trending/tv/$timeWindow');
    return data['results'] as List<dynamic>;
  }

  static Future<List<dynamic>> getPopularMovies({int page = 1}) async {
    final data = await _get('/movie/popular', params: {'page': '$page'});
    return data['results'] as List<dynamic>;
  }

  static Future<List<dynamic>> getTopRatedMovies({int page = 1}) async {
    final data = await _get('/movie/top_rated', params: {'page': '$page'});
    return data['results'] as List<dynamic>;
  }

  static Future<List<dynamic>> getPopularTv({int page = 1}) async {
    final data = await _get('/tv/popular', params: {'page': '$page'});
    return data['results'] as List<dynamic>;
  }

  static Future<List<dynamic>> getTopRatedTv({int page = 1}) async {
    final data = await _get('/tv/top_rated', params: {'page': '$page'});
    return data['results'] as List<dynamic>;
  }

  static Future<List<dynamic>> getNowPlayingMovies({int page = 1}) async {
    final data = await _get('/movie/now_playing', params: {'page': '$page'});
    return data['results'] as List<dynamic>;
  }

  static Future<Map<String, dynamic>> getMovieDetails(int id) async {
    return _get('/movie/$id', params: {'append_to_response': 'credits,recommendations,similar,images', 'include_image_language': 'en,null'});
  }

  static Future<Map<String, dynamic>> getTvDetails(int id) async {
    return _get('/tv/$id', params: {'append_to_response': 'credits,recommendations,similar,images,external_ids', 'include_image_language': 'en,null'});
  }

  static Future<Map<String, dynamic>> getTvSeason(int tvId, int seasonNumber) async {
    return _get('/tv/$tvId/season/$seasonNumber');
  }

  static Future<List<dynamic>> searchMulti(String query, {int page = 1}) async {
    if (query.trim().isEmpty) return [];
    final data = await _get('/search/multi', params: {'query': query, 'page': '$page'});
    return data['results'] as List<dynamic>;
  }

  /// Find a TMDB item by IMDB ID. Returns a movie/tv map or null.
  static Future<Map<String, dynamic>?> findByImdbId(String imdbId, {String mediaType = 'movie'}) async {
    try {
      final data = await _get('/find/$imdbId', params: {'external_source': 'imdb_id'});
      // Check movie results first
      final movies = data['movie_results'] as List? ?? [];
      if (movies.isNotEmpty) {
        final movie = Map<String, dynamic>.from(movies.first);
        movie['media_type'] = 'movie';
        return movie;
      }
      // Then TV results
      final tvResults = data['tv_results'] as List? ?? [];
      if (tvResults.isNotEmpty) {
        final tv = Map<String, dynamic>.from(tvResults.first);
        tv['media_type'] = 'tv';
        return tv;
      }
    } catch (e) {
      // Silently fail
    }
    return null;
  }
}
