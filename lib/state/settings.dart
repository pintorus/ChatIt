import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class Settings extends ChangeNotifier {
  String baseUrl = 'http://localhost:8080';
  String apiKey = '';
  String sessionToken = '';
  String userEmail = '';
  String chatModel = '';
  String imageModel = '';
  String sttModel = 'whisper-1';
  String ttsModel = 'tts-1';
  String ttsVoice = '';
  String systemPrompt = 'Tu es Chat It, un assistant utile. Réponds dans la langue de l\'utilisateur.';
  double temperature = 0.7;
  bool autoSpeak = false;
  bool darkMode = false;

  late SharedPreferences _p;

  Future<void> load() async {
    _p = await SharedPreferences.getInstance();
    baseUrl = _p.getString('baseUrl') ?? baseUrl;
    apiKey = _p.getString('apiKey') ?? apiKey;
    sessionToken = _p.getString('sessionToken') ?? sessionToken;
    userEmail = _p.getString('userEmail') ?? userEmail;
    chatModel = _p.getString('chatModel') ?? chatModel;
    imageModel = _p.getString('imageModel') ?? imageModel;
    sttModel = _p.getString('sttModel') ?? sttModel;
    ttsModel = _p.getString('ttsModel') ?? ttsModel;
    ttsVoice = _p.getString('ttsVoice') ?? ttsVoice;
    systemPrompt = _p.getString('systemPrompt') ?? systemPrompt;
    temperature = _p.getDouble('temperature') ?? temperature;
    autoSpeak = _p.getBool('autoSpeak') ?? autoSpeak;
    darkMode = _p.getBool('darkMode') ?? darkMode;
  }

  Future<void> save() async {
    await _p.setString('baseUrl', baseUrl);
    await _p.setString('apiKey', apiKey);
    await _p.setString('sessionToken', sessionToken);
    await _p.setString('userEmail', userEmail);
    await _p.setString('chatModel', chatModel);
    await _p.setString('imageModel', imageModel);
    await _p.setString('sttModel', sttModel);
    await _p.setString('ttsModel', ttsModel);
    await _p.setString('ttsVoice', ttsVoice);
    await _p.setString('systemPrompt', systemPrompt);
    await _p.setDouble('temperature', temperature);
    await _p.setBool('autoSpeak', autoSpeak);
    await _p.setBool('darkMode', darkMode);
    notifyListeners();
  }
}
