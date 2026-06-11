import 'package:shared_preferences/shared_preferences.dart';

class AppSettings {
  AppSettings._();
  static final AppSettings instance = AppSettings._();

  int recordingDurationLimit = 60;
  String? activeListId;
  String? activeListTitle;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    recordingDurationLimit = prefs.getInt('recording_duration_limit') ?? 60;
    activeListId = prefs.getString('active_list_id');
    activeListTitle = prefs.getString('active_list_title');
  }

  Future<void> setRecordingDurationLimit(int seconds) async {
    recordingDurationLimit = seconds;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('recording_duration_limit', seconds);
  }

  Future<void> setActiveList(String? id, String? title) async {
    activeListId = id;
    activeListTitle = title;
    final prefs = await SharedPreferences.getInstance();
    if (id == null) {
      await prefs.remove('active_list_id');
      await prefs.remove('active_list_title');
    } else {
      await prefs.setString('active_list_id', id);
      await prefs.setString('active_list_title', title ?? '');
    }
  }
}
