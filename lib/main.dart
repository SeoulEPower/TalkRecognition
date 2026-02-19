import 'dart:async';
import 'dart:io';
import 'dart:typed_data';


import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // MethodChannel, EventChannel
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:torch_light/torch_light.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:flutter_bluetooth_classic_serial/flutter_bluetooth_classic.dart';
import 'dart:convert';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  tz.initializeTimeZones();
  
  // Get timezone via MethodChannel (replaces flutter_timezone)
  String timeZoneName = 'Asia/Seoul'; // fallback
  try {
    const platform = MethodChannel('com.example.talk_recognition/tone');
    timeZoneName = await platform.invokeMethod('getTimezone') ?? 'Asia/Seoul';
  } catch (e) {
    print("DEBUG: Failed to get timezone, using fallback: $e");
  }
  tz.setLocalLocation(tz.getLocation(timeZoneName));
  
  print("DEBUG: Set Local Timezone: $timeZoneName");

  runApp(const VoiceAssistantApp());
}

class VoiceAssistantApp extends StatelessWidget {
  const VoiceAssistantApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Voice Assistant',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const VoiceAssistantScreen(),
    );
  }
}

class VoiceAssistantScreen extends StatefulWidget {
  const VoiceAssistantScreen({super.key});

  @override
  State<VoiceAssistantScreen> createState() => _VoiceAssistantScreenState();
}

class _VoiceAssistantScreenState extends State<VoiceAssistantScreen> with SingleTickerProviderStateMixin {
  late stt.SpeechToText _speech;
  late FlutterTts _flutterTts;
  late FlutterLocalNotificationsPlugin _flutterLocalNotificationsPlugin;
  late AnimationController _animationController;
  late Animation<double> _pulseAnimation;

  bool _isListening = false;
  String _text = 'Listening...';
  String _status = 'Standby';
  final List<String> _history = [];
  String _currentTime = '';
  Timer? _clockTimer;
  Timer? _alarmTimer;
  Timer? _alarmSoundTimer; // 알람 사운드 루프 타이머
  bool _isAlarmRinging = false;
  int _alarmCount = 0;
  List<Map<String, String>> _apps = [];

  // 마지막 예약 알람 정보
  int? _lastAlarmId;
  String? _lastAlarmTimeStr;

  // SMS 대화 상태
  String? _pendingSmsPhone;
  String? _pendingSmsName;
  String? _pendingSmsMessage; // 확인 대기 중인 메시지

  // 메모 상태
  bool _isMemoMode = false;
  final List<String> _memoBuffer = [];
  int _memoSilenceCount = 0; // 침묵 타임아웃 카운터 (무한루프 방지)

  // PiP 상태
  bool _isInPipMode = false;
  static const EventChannel _pipEventChannel = EventChannel('com.example.talk_recognition/pip');

  // Bluetooth Classic 상태
  final FlutterBluetoothClassic _bluetooth = FlutterBluetoothClassic();
  StreamSubscription<BluetoothConnectionState>? _connectionSubscription;
  StreamSubscription<BluetoothData>? _dataSubscription;
  bool _isScanning = false;
  bool _isBleConnected = false;
  bool _isAdcMonitoring = false;
  bool _isBlinking = false;
  List<bool> _pinStates = [false, false, false, false]; // 4채널 GPIO
  List<int> _adcValues = [0, 0]; // 2채널 ADC (0~4095)
  String _bleStatus = '미연결';
  String _rxBuffer = ''; // 수신 데이터 버퍼

  void _addToHistory(String command) {
    setState(() {
      _history.insert(0, command);
      if (_history.length > 20) {
        _history.removeLast();
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _speech = stt.SpeechToText();
    _flutterTts = FlutterTts();
    _flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();

    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.2).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeInOut),
    );

    _initTts();
    _initNotifications();
    _requestPermissions();
    _loadInstalledApps();
    _initPipListener();
    _startClock();
  }

  void _initPipListener() {
    _pipEventChannel.receiveBroadcastStream().listen((event) {
      final isInPip = event as bool;
      setState(() {
        _isInPipMode = isInPip;
      });
      // PiP 진입 시 자동으로 음성 인식 시작
      if (isInPip && !_isListening) {
        Future.delayed(const Duration(milliseconds: 500), () {
          _listen();
        });
      }
    });

    // Android에서 PiP RemoteAction(마이크 버튼) 클릭 시 호출됨
    const platform = MethodChannel('com.example.talk_recognition/tone');
    platform.setMethodCallHandler((call) async {
      if (call.method == 'toggleMic') {
        if (_isListening) {
          _speech.stop();
          setState(() => _isListening = false);
        } else {
          _listen();
        }
      }
      return null;
    });
  }

  void _startClock() {
    _currentTime = DateFormat('HH:mm:ss').format(DateTime.now());
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {
          _currentTime = DateFormat('HH:mm:ss').format(DateTime.now());
        });
      }
    });
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    _animationController.dispose();
    _connectionSubscription?.cancel();
    _dataSubscription?.cancel();
    try { _bluetooth.disconnect(); } catch (_) {}
    super.dispose();
  }

  Future<void> _requestPermissions() async {
    final notificationStatus = await Permission.notification.request();
    final microphoneStatus = await Permission.microphone.request();
    final alarmStatus = await Permission.scheduleExactAlarm.request();
    final cameraStatus = await Permission.camera.request(); // For Flashlight
    final contactsStatus = await Permission.contacts.request();

    print("DEBUG: Notification: $notificationStatus");
    print("DEBUG: Microphone: $microphoneStatus");
    print("DEBUG: Alarm: $alarmStatus");
    final smsStatus = await Permission.sms.request();

    print("DEBUG: Camera: $cameraStatus");
    print("DEBUG: Contacts: $contactsStatus");
    print("DEBUG: SMS: $smsStatus");

    // BLE 권한
    final btScanStatus = await Permission.bluetoothScan.request();
    final btConnectStatus = await Permission.bluetoothConnect.request();
    final locationStatus = await Permission.location.request();
    print("DEBUG: BT Scan: $btScanStatus");
    print("DEBUG: BT Connect: $btConnectStatus");
    print("DEBUG: Location: $locationStatus");

    // 외부 저장소 권한 (메모 저장용)
    final storageStatus = await Permission.storage.request();
    print("DEBUG: Storage: $storageStatus");
    if (!storageStatus.isGranted) {
      final manageStatus = await Permission.manageExternalStorage.request();
      print("DEBUG: ManageStorage: $manageStatus");
    }
    
    if (alarmStatus != PermissionStatus.granted) {
       _speak("정확한 알람을 위해 권한 설정이 필요할 수 있어요.");
       // Open settings if permanently denied
       if (alarmStatus.isPermanentlyDenied) {
         openAppSettings();
       }
    }
    
    if (notificationStatus != PermissionStatus.granted) {
      _speak("알림 권한이 없으면 알람을 받을 수 없어요.");
       if (notificationStatus.isPermanentlyDenied) {
         openAppSettings();
       }
    }
  }

  Future<void> _initTts() async {
    await _flutterTts.setLanguage("ko-KR");
    await _flutterTts.setPitch(1.0);
    await _flutterTts.setSpeechRate(0.5);
  }

  Future<void> _initNotifications() async {
    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    const InitializationSettings initializationSettings =
        InitializationSettings(android: initializationSettingsAndroid);

    await _flutterLocalNotificationsPlugin.initialize(
      initializationSettings,
      onDidReceiveNotificationResponse: (details) {
        print("DEBUG: Notification clicked: ${details.payload}");
        _startAlarmSound(); // Start alarm loop when notification is clicked
      },
    );
    
    // Create channel explicitly for Android 8.0+
    const AndroidNotificationChannel channel = AndroidNotificationChannel(
      'voice_assistant_channel', // id
      'Voice Assistant Alarms', // title
      description: 'Channel for voice assistant alarms', // description
      importance: Importance.max,
      playSound: true,
    );

    await _flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);
        
    print("DEBUG: Notification initialized and channel created.");
  }

  // SMS 대기 상태인지 확인
  bool get _isWaitingForSms => _pendingSmsPhone != null || _pendingSmsMessage != null;

   Future<void> _listen() async {
    if (!_isListening) {
      bool available = await _speech.initialize(
        onStatus: (status) {
          setState(() {
            _status = status;
            if (status == 'done' || status == 'notListening') {
              _isListening = false;
            }
          });
          // SMS 대기 중이면 자동으로 다시 듣기 (메모 모드는 onResult에서 처리)
          if ((status == 'done' || status == 'notListening') && _isWaitingForSms) {
            Future.delayed(const Duration(milliseconds: 500), () {
              if (_isWaitingForSms) {
                _listen();
              }
            });
          }
        },
        onError: (errorNotification) {
          setState(() {
            _status = errorNotification.errorMsg;
            _isListening = false;
          });
          if (_isWaitingForSms) {
            print("DEBUG: STT error during SMS wait, retrying: ${errorNotification.errorMsg}");
            Future.delayed(const Duration(milliseconds: 500), () {
              if (_isWaitingForSms) {
                _listen();
              }
            });
          } else if (_isMemoMode) {
            // 메모 모드 에러 시 리스닝 중지, 사용자가 탭해서 재시작
            print("DEBUG: STT error in memo mode: ${errorNotification.errorMsg}");
          } else {
            _speak("뭐라구?");
          }
        },
      );

      if (available) {
        setState(() => _isListening = true);
        _speech.listen(
          onResult: (val) {
            setState(() {
              _text = val.recognizedWords;
            });
            if (val.finalResult) {
              // 메모 모드일 때
              if (_isMemoMode) {
                final words = val.recognizedWords.trim();
                if (words.contains('취소')) {
                  // 메모 취소
                  setState(() {
                    _isMemoMode = false;
                    _memoBuffer.clear();
                    _memoSilenceCount = 0;
                  });
                  _addToHistory('❌ 메모 취소');
                  _speak('메모를 취소했어요.');
                } else if (words.contains('저장')) {
                  final beforeSave = words.replaceAll(RegExp(r'저장(해|하자|해줘)?'), '').trim();
                  if (beforeSave.isNotEmpty) {
                    _memoBuffer.add(beforeSave);
                  }
                  _saveMemo();
                } else if (words.isNotEmpty) {
                  _memoBuffer.add(words);
                  _addToHistory('📝 $words');
                  _memoSilenceCount = 0;
                  // initialize 없이 바로 다시 리스닝
                  Future.delayed(const Duration(milliseconds: 100), () {
                    if (_isMemoMode) _listenMemo();
                  });
                } else {
                  // 침묵 타임아웃 — 자동 재시작 (최대 3회)
                  _memoSilenceCount++;
                  if (_memoSilenceCount < 3 && _isMemoMode) {
                    Future.delayed(const Duration(milliseconds: 300), () {
                      if (_isMemoMode) _listenMemo();
                    });
                  }
                }
              } else {
                _processCommand(val.recognizedWords);
              }
            }
          },
          localeId: 'ko_KR',
          pauseFor: const Duration(seconds: 10),
        );
      } else {
         setState(() => _status = '음성 인식 불가');
         _speak("음성 인식을 사용할 수 없어요.");
      }
    } else {
      setState(() => _isListening = false);
      _speech.stop();
    }
  }

  // 메모 모드 전용: initialize 없이 바로 listen만 호출 (빠른 재시작)
  void _listenMemo() {
    if (_isListening || !_isMemoMode) return;
    setState(() => _isListening = true);
    _speech.listen(
      onResult: (val) {
        setState(() {
          _text = val.recognizedWords;
        });
        if (val.finalResult) {
          final words = val.recognizedWords.trim();
          if (words.contains('취소')) {
            setState(() {
              _isMemoMode = false;
              _memoBuffer.clear();
              _memoSilenceCount = 0;
            });
            _addToHistory('❌ 메모 취소');
            _speak('메모를 취소했어요.');
          } else if (words.contains('저장')) {
            final beforeSave = words.replaceAll(RegExp(r'저장(해|하자|해줘)?'), '').trim();
            if (beforeSave.isNotEmpty) {
              _memoBuffer.add(beforeSave);
            }
            _saveMemo();
          } else if (words.isNotEmpty) {
            _memoBuffer.add(words);
            _addToHistory('📝 $words');
            _memoSilenceCount = 0;
            Future.delayed(const Duration(milliseconds: 100), () {
              if (_isMemoMode) _listenMemo();
            });
          } else {
            _memoSilenceCount++;
            if (_memoSilenceCount < 3 && _isMemoMode) {
              Future.delayed(const Duration(milliseconds: 300), () {
                if (_isMemoMode) _listenMemo();
              });
            }
          }
        }
      },
      localeId: 'ko_KR',
      pauseFor: const Duration(seconds: 10),
    );
  }

  // 저장된 메모 목록 확인 (다이얼로그)
  Future<void> _listMemos() async {
    try {
      final memoDir = Directory('/storage/emulated/0/Download/음성메모');
      if (!await memoDir.exists()) {
        await _speak("저장된 메모가 없어요.");
        return;
      }
      final files = await memoDir.list().where((f) => f.path.endsWith('.txt')).toList();
      if (files.isEmpty) {
        await _speak("저장된 메모가 없어요.");
        return;
      }
      // 파일명 리스트 준비
      files.sort((a, b) => b.path.compareTo(a.path));
      final fileNames = files.map((f) => f.path.split('/').last.replaceAll('.txt', '')).toList();

      if (!mounted) return;
      await _speak("저장된 메모가 ${files.length}개 있어요.");
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF1A1A2E),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Color(0xFF00E5FF), width: 1),
          ),
          title: Text(
            '📋 메모 목록 (${files.length}개)',
            style: const TextStyle(color: Color(0xFF00E5FF), fontSize: 16),
          ),
          content: SizedBox(
            width: double.maxFinite,
            height: 300,
            child: ListView.builder(
              itemCount: fileNames.length,
              itemBuilder: (context, index) {
                return ListTile(
                  leading: const Icon(Icons.description, color: Color(0xFF00E5FF), size: 20),
                  title: Text(
                    fileNames[index],
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    _showMemoContent('  📄 ${fileNames[index]}');
                  },
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('닫기', style: TextStyle(color: Color(0xFF00E5FF))),
            ),
          ],
        ),
      );
    } catch (e) {
      print("DEBUG: List memos error: $e");
      await _speak("메모 목록을 불러올 수 없어요.");
    }
  }

  // 메모 파일 내용을 다이얼로그로 표시
  Future<void> _showMemoContent(String historyEntry) async {
    try {
      final name = historyEntry.replaceAll(RegExp(r'[📄📋\s]'), '').trim();
      final file = File('/storage/emulated/0/Download/음성메모/$name.txt');
      if (!await file.exists()) {
        _speak("파일을 찾을 수 없어요.");
        return;
      }

      final content = await file.readAsString();

      if (!mounted) return;
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF1A1A2E),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Color(0xFF00E5FF), width: 1),
          ),
          title: Text(
            '📝 $name',
            style: const TextStyle(color: Color(0xFF00E5FF), fontSize: 16),
          ),
          content: SingleChildScrollView(
            child: Text(
              content,
              style: const TextStyle(color: Colors.white70, fontSize: 14, height: 1.5),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('닫기', style: TextStyle(color: Color(0xFF00E5FF))),
            ),
          ],
        ),
      );
    } catch (e) {
      print("DEBUG: Show memo error: $e");
      _speak("메모를 열 수 없어요.");
    }
  }

  Future<void> _processCommand(String command) async {
    final commandLower = command.trim();
    print("DEBUG: Processing command: '$commandLower'");

    _addToHistory(commandLower);

    // "취소" 명령 — SMS 대기 상태 해제 또는 마지막 알람 취소
    if (commandLower.contains('취소')) {
      if (_isWaitingForSms) {
        _pendingSmsPhone = null;
        _pendingSmsName = null;
        _pendingSmsMessage = null;
        await _speak("취소했어요.");
        return;
      }
      if (_lastAlarmId != null) {
        await _flutterLocalNotificationsPlugin.cancel(_lastAlarmId!);
        _alarmTimer?.cancel();
        final cancelledTime = _lastAlarmTimeStr ?? '예약된 알람';
        _lastAlarmId = null;
        _lastAlarmTimeStr = null;
        await _speak("$cancelledTime 알림을 취소했어요.");
        return;
      }
      await _speak("취소할 예약이 없어요.");
      return;
    }

    // SMS 확인 대기 중 ("보낼까요?" 응답)
    if (_pendingSmsMessage != null) {
      final phone = _pendingSmsPhone!;
      final name = _pendingSmsName ?? phone;
      final message = _pendingSmsMessage!;
      _pendingSmsPhone = null;
      _pendingSmsName = null;
      _pendingSmsMessage = null;
      if (commandLower.contains('네') || commandLower.contains('응') || 
          commandLower.contains('보내') || commandLower.contains('그래') ||
          commandLower.contains('맞아') || commandLower.contains('오케이')) {
        await _sendSmsDirectly(phone, message, name);
      } else {
        await _speak("문자 보내기를 취소했어요.");
      }
      return;
    }

    // SMS 메시지 내용 대기 중이면 확인 단계로
    if (_pendingSmsPhone != null) {
      final phone = _pendingSmsPhone!;
      final name = _pendingSmsName ?? phone;
      // 메시지 내용을 받았으니 확인 요청
      _pendingSmsMessage = commandLower;
      await _speak("$name 님에게 '$commandLower' 라고 보낼까요?");
      await Future.delayed(const Duration(milliseconds: 1500));
      _listen();
      return;
    }

    // ===== BLE/ESP32 명령 (최우선) =====
    final bool _isBleKeyword = commandLower.contains('esp') || commandLower.contains('이에스피') ||
        commandLower.contains('블루투스') || commandLower.contains('디바이스');
    if (_isBleKeyword &&
        (commandLower.contains('연결') || commandLower.contains('접속') || commandLower.contains('커넥트'))) {
      _scanAndConnect();
    } else if (_isBleKeyword &&
               (commandLower.contains('끊') || commandLower.contains('해제') || commandLower.contains('차단'))) {
      _disconnectBle();
    } else if ((commandLower.contains('센서') || commandLower.contains('adc')) &&
               (commandLower.contains('보여') || commandLower.contains('시작') || commandLower.contains('확인'))) {
      _sendBleCommand('ADC:START');
      setState(() => _isAdcMonitoring = true);
      await _speak('센서 모니터링을 시작합니다.');
    } else if ((commandLower.contains('센서') || commandLower.contains('adc')) &&
               (commandLower.contains('꺼') || commandLower.contains('중지') || commandLower.contains('멈'))) {
      _sendBleCommand('ADC:STOP');
      setState(() => _isAdcMonitoring = false);
      await _speak('센서 모니터링을 중지합니다.');
    } else if (_isBleKeyword && commandLower.contains('상태')) {
      _sendBleCommand('STATUS');
      final states = List.generate(4, (i) => '${i + 1}번 ${_pinStates[i] ? "켜짐" : "꺼짐"}').join(', ');
      await _speak('ESP 상태: $states');
    } else if ((commandLower.contains('블링크') || commandLower.contains('깜빡')) &&
               (commandLower.contains('시작') || commandLower.contains('켜'))) {
      _sendBleCommand('FUNC:blink');
      await _speak('LED 블링크를 시작합니다.');
    } else if ((commandLower.contains('블링크') || commandLower.contains('깜빡')) &&
               (commandLower.contains('중지') || commandLower.contains('꺼') || commandLower.contains('멈'))) {
      _sendBleCommand('FUNC:blinkStop');
      await _speak('LED 블링크를 중지합니다.');
    } else if (_isBleConnected && _matchEspPinCommand(commandLower)) {
      // "N번 켜/꺼" 패턴이 매칭되면 _matchEspPinCommand 내에서 처리
    } else if ((commandLower.contains('전체') || commandLower.contains('다 ') || commandLower.contains('모두')) &&
               _isBleConnected &&
               (commandLower.contains('켜') || commandLower.contains('꺼'))) {
      final on = commandLower.contains('켜');
      _sendBleCommand(on ? 'ALL:ON' : 'ALL:OFF');
      await _speak(on ? '전체 출력을 켰습니다.' : '전체 출력을 껐습니다.');
    } else if (_isBleConnected && _matchFuncCommand(commandLower)) {
      // "{name} 실행/시작/중지" 패턴 처리
    // ===== 기존 명령어 =====
    } else if (commandLower.contains('몇 시') || commandLower.contains('시간')) {
      _speakTime();
    } else if (commandLower.contains('알려줘') || commandLower.contains('알려 줘') || 
               commandLower.contains('알람') || commandLower.contains('알림')) {
      _processAlarm(commandLower);
    } else if (commandLower.contains('도움말') || commandLower.contains('사용법') || 
               commandLower.contains('뭐 할 수 있어') || commandLower.contains('가능한')) {
      await _speak("시간 확인, 알람 설정, ESP32 제어, 그리고 손전등을 켜거나 끌 수 있습니다.");
    } else if (commandLower.contains('불 켜') || commandLower.contains('불켜')) {
      _controlFlashlight(true);
    } else if (commandLower.contains('불 꺼') || commandLower.contains('불꺼')) {
      _controlFlashlight(false);
    } else if (commandLower.contains('전화') && (commandLower.contains('걸어') || commandLower.contains('해'))) {
      _processCallCommand(commandLower);
    } else if ((commandLower.contains('카톡') || commandLower.contains('카카오톡')) && 
               (commandLower.contains('보내') || commandLower.contains('전해'))) {
      _processKakaoCommand(commandLower);
    } else if (commandLower.contains('문자') && (commandLower.contains('보내'))) {
      _processSmsCommand(commandLower);
    } else if (commandLower.contains('실행') || commandLower.contains('열어') || commandLower.contains('켜')) {
      _processAppLaunchCommand(commandLower);
    } else if (commandLower.contains('메모') && (commandLower.contains('확인') || commandLower.contains('목록') || commandLower.contains('보여'))) {
      _listMemos();
    } else if (commandLower.contains('메모')) {
      setState(() {
        _isMemoMode = true;
        _memoBuffer.clear();
        _memoSilenceCount = 0;
      });
      await _speak("메모 시작. 저장해 라고 말하면 저장됩니다.");
      Future.delayed(const Duration(milliseconds: 1500), () => _listen());
    } else if (commandLower.contains('더하기') || commandLower.contains('빼기') || 
               commandLower.contains('곱하기') || commandLower.contains('나누기') ||
               commandLower.contains('플러스') || commandLower.contains('마이너스') ||
               commandLower.contains('+') || commandLower.contains('-') ||
               commandLower.contains('*') || commandLower.contains('×') ||
               commandLower.contains('/') || commandLower.contains('÷')) {
      _processCalculation(commandLower);
    } else {
       if (commandLower.isNotEmpty) {
          await _speak("뭐라구?");
       }
    }
  }

  Future<void> _speakTime() async {
    final now = DateTime.now();
    final formattedTime = DateFormat('a h시 m분').format(now)
        .replaceAll('AM', '오전')
        .replaceAll('PM', '오후');
    
    await _speak("현재 시각은 $formattedTime입니다.");
  }

  Future<void> _processAlarm(String command) async {
    // 1. Try Absolute Time (e.g., "10시 30분", "오후 2시에 알려줘")
    final RegExp absolutePattern = RegExp(r'(오전|오후)?\s*(\d{1,2})\s*시\s*((\d{1,2})\s*분|반)?');
    final absoluteMatch = absolutePattern.firstMatch(command);

    if (absoluteMatch != null && !command.contains('뒤') && !command.contains('후')) {
      // It looks like an absolute time command
      String? ampm = absoluteMatch.group(1);
      int hour = int.parse(absoluteMatch.group(2)!);
      String? minutePart = absoluteMatch.group(3);
      int minute = 0;

      if (minutePart != null) {
        if (minutePart.contains('반')) {
          minute = 30;
        } else {
          minute = int.parse(absoluteMatch.group(4)!);
        }
      }

      // Logic to determine actual hour
      if (ampm == '오후') {
        if (hour < 12) hour += 12;
      } else if (ampm == '오전') {
        if (hour == 12) hour = 0;
      } else {
        // No AM/PM specified
        // Heuristic: If hour <= 12, we need to decide.
        // If 13+, it's 24h format.
        if (hour <= 12) {
           // We will decide based on whether the time has passed today.
           // This logic happens inside _scheduleAbsoluteNotification
        }
      }

      await _scheduleAbsoluteNotification(hour, minute, ampm != null);
      return;
    }

    // 2. Try Relative Time (e.g., "30분 뒤에", "1시간 뒤")
    // Use existing logic
    final RegExp explicitPattern = RegExp(r'(\d+)\s*(초|분|시간)');
    final explicitMatch = explicitPattern.firstMatch(command);

    if (explicitMatch != null) {
      int value = int.parse(explicitMatch.group(1)!);
      String unit = explicitMatch.group(2)!;
      int durationInSeconds = 0;
      String unitText = unit;

      if (unit == '초') {
        durationInSeconds = value;
      } else if (unit == '분') {
        durationInSeconds = value * 60;
      } else if (unit == '시간') {
        durationInSeconds = value * 3600;
      }
      
      _scheduleRelativeNotification(durationInSeconds, "$value$unitText");
      return;
    }

    // 3. Fallback: Number + "뒤에" (Assume minutes)
    final RegExp implicitPattern = RegExp(r'(\d+)\s*(뒤|후)');
    final implicitMatch = implicitPattern.firstMatch(command);
    
    if (implicitMatch != null) {
       int value = int.parse(implicitMatch.group(1)!);
       _scheduleRelativeNotification(value * 60, "$value분");
       return;
    }

    await _speak("시간 설정을 이해하지 못했어요. '3분 뒤에 알려줘' 또는 '오후 5시에 알려줘' 처럼 말씀해 주세요.");
  }

  Future<void> _scheduleAbsoluteNotification(int hour, int minute, bool amPmExplicit) async {
    final now = tz.TZDateTime.now(tz.local);
    var scheduledDate = tz.TZDateTime(tz.local, now.year, now.month, now.day, hour, minute);

    // If AM/PM was NOT explicit, we try to guess.
    // E.g. User said "10시". 
    // If 10:00 passed, maybe they mean 22:00 (10 PM)?
    if (!amPmExplicit && hour <= 12) {
       if (scheduledDate.isBefore(now)) {
         // passed. Check valid PM time?
         // If hour is 10, try 22.
         var potentialPm = scheduledDate.add(const Duration(hours: 12));
         if (potentialPm.isAfter(now)) {
           scheduledDate = potentialPm;
         } else {
           // Even PM passed (or user meant 12 PM which is noon, vs 12 AM).
           // If mostly passed, schedule for tomorrow AM.
           scheduledDate = scheduledDate.add(const Duration(days: 1));
         }
       }
    } else {
       // AM/PM explicit OR 24h format.
       // If passed, schedule for tomorrow.
       if (scheduledDate.isBefore(now)) {
          scheduledDate = scheduledDate.add(const Duration(days: 1));
       }
    }

    await _scheduleNotificationAt(scheduledDate);
    
    // Announce
    String timeStr = DateFormat('M월 d일 a h시 m분').format(scheduledDate)
      .replaceAll('AM', '오전').replaceAll('PM', '오후');
    await _speak("$timeStr에 알림을 설정했어요.");
  }

  Future<void> _scheduleRelativeNotification(int durationInSeconds, String timeText) async {
      if (durationInSeconds > 0) {
        final now = tz.TZDateTime.now(tz.local);
        final scheduledDate = now.add(Duration(seconds: durationInSeconds));
        await _scheduleNotificationAt(scheduledDate);
        await _speak("$timeText 뒤에 알림을 설정했어요.");
      } else {
        await _speak("시간을 잘못 이해했어요.");
      }
  }

  Future<void> _scheduleNotificationAt(tz.TZDateTime scheduledTime) async {
    final AndroidNotificationDetails androidPlatformChannelSpecifics =
        AndroidNotificationDetails(
      'alarm_channel_v2',
      'Voice Assistant Alarms',
      channelDescription: 'Channel for voice assistant alarms',
      importance: Importance.max,
      priority: Priority.high,
      category: AndroidNotificationCategory.alarm,
      fullScreenIntent: true,       // 화면 OFF 시 화면 깨움
      ongoing: false,
      autoCancel: true,
      sound: RawResourceAndroidNotificationSound('alarm'),
      playSound: true,
      enableVibration: true,
      vibrationPattern: Int64List.fromList([0, 1000, 500, 1000, 500, 1000]),
    );
    
    final NotificationDetails platformChannelSpecifics =
        NotificationDetails(android: androidPlatformChannelSpecifics);


    try {
      final alarmId = scheduledTime.millisecondsSinceEpoch ~/ 1000;
      await _flutterLocalNotificationsPlugin.zonedSchedule(
        alarmId,
        '알람',
        '설정하신 시간이 되었습니다!',
        scheduledTime,
        platformChannelSpecifics,
        androidScheduleMode: AndroidScheduleMode.alarmClock,
        uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
      );

      // 마지막 알람 정보 저장
      _lastAlarmId = alarmId;
      _lastAlarmTimeStr = DateFormat('a h시 m분').format(scheduledTime)
          .replaceAll('AM', '오전').replaceAll('PM', '오후');

      print("DEBUG: Notification scheduled successfully for $scheduledTime (id: $alarmId)");
      
      final now = tz.TZDateTime.now(tz.local);
      final duration = scheduledTime.difference(now);
      if (duration.isNegative) return;

      _alarmTimer?.cancel();
      
      _alarmTimer = Timer(duration, () {
        if (mounted) _startAlarmSound();
      });
    } catch (e) {
      print("DEBUG: Error scheduling notification: $e");
      await _speak("알림 설정 중 에러가 발생했어요.");
    }
  }

  Future<void> _showImmediateNotification() async {
    const AndroidNotificationDetails androidPlatformChannelSpecifics =
        AndroidNotificationDetails(
      'voice_assistant_channel',
      'Voice Assistant Alarms',
      channelDescription: 'Channel for voice assistant alarms',
      importance: Importance.max,
      priority: Priority.high,
      ticker: 'ticker',
    );
    const NotificationDetails platformChannelSpecifics =
        NotificationDetails(android: androidPlatformChannelSpecifics);

    await _flutterLocalNotificationsPlugin.show(
        1,
        '즉시 알림',
        '이 알림이 보이면 권한은 정상입니다.',
        platformChannelSpecifics,
    );
    print("DEBUG: Immediate notification sent.");
  }

  Future<void> _speak(String text) async {
    await _flutterTts.speak(text);
  }

  Future<void> _loadInstalledApps() async {
    try {
      const platform = MethodChannel('com.example.talk_recognition/tone');
      final List<dynamic> apps = await platform.invokeMethod('getInstalledApps');
      setState(() {
        _apps = apps.map((e) => Map<String, String>.from(e as Map)).toList();
      });
      print("DEBUG: Loaded ${apps.length} apps.");
    } catch (e) {
      print("DEBUG: Error loading apps: $e");
    }
  }

  /// 음성 명령에서 연락처 이름을 추출합니다.
  /// "엄마한테 전화해" → "엄마", "김철수에게 문자 보내" → "김철수"
  String? _extractContactName(String command) {
    // "한테", "에게", "께", "에" 앞의 단어를 이름으로 추출
    final RegExp namePattern = RegExp(r'(.+?)(?:한테|에게|께|에)\s*(?:전화|문자)');
    final match = namePattern.firstMatch(command);
    if (match != null) {
      String name = match.group(1)!.trim();
      // 불필요한 접두사 제거 ("전화", "문자" 등)
      name = name.replaceAll(RegExp(r'^(전화|문자)\s*'), '').trim();
      if (name.isNotEmpty) return name;
    }
    return null;
  }

  /// 이름으로 연락처를 검색하여 전화번호를 반환합니다.
  Future<String?> _findPhoneByName(String name) async {
    try {
      if (!await FlutterContacts.requestPermission(readonly: true)) {
        await _speak("연락처 접근 권한이 필요합니다.");
        return null;
      }
      final contacts = await FlutterContacts.getContacts(withProperties: true);
      
      // 1차: 정확히 일치
      for (final contact in contacts) {
        if (contact.displayName == name && contact.phones.isNotEmpty) {
          return contact.phones.first.number;
        }
      }
      
      // 2차: 부분 일치 (이름에 포함)
      for (final contact in contacts) {
        if (contact.displayName.contains(name) && contact.phones.isNotEmpty) {
          return contact.phones.first.number;
        }
      }
      
      return null;
    } catch (e) {
      print("DEBUG: Error searching contacts: $e");
      return null;
    }
  }

  Future<void> _processCallCommand(String command) async {
    // 1. 먼저 전화번호 직접 입력 확인
    final RegExp phonePattern = RegExp(r'[\d-]{3,}');
    final match = phonePattern.firstMatch(command);
    if (match != null) {
      final number = match.group(0)!.replaceAll('-', '');
      final Uri launchUri = Uri(scheme: 'tel', path: number);
      if (await canLaunchUrl(launchUri)) {
        await launchUrl(launchUri);
        await _speak("전화를 겁니다.");
      } else {
        await _speak("전화를 걸 수 없습니다.");
      }
      return;
    }

    // 2. 연락처 이름으로 검색
    final name = _extractContactName(command);
    if (name != null) {
      await _speak("$name 연락처를 찾고 있어요.");
      final phone = await _findPhoneByName(name);
      if (phone != null) {
        final Uri launchUri = Uri(scheme: 'tel', path: phone);
        if (await canLaunchUrl(launchUri)) {
          await launchUrl(launchUri);
          await _speak("$name 님에게 전화를 겁니다.");
        } else {
          await _speak("전화를 걸 수 없습니다.");
        }
      } else {
        await _speak("$name 님의 연락처를 찾을 수 없어요.");
      }
    } else {
      await _speak("전화할 대상을 말씀해 주세요. 예: 엄마한테 전화해.");
    }
  }

  Future<void> _processSmsCommand(String command) async {
    String? targetPhone;
    String? targetName;

    // 1. 전화번호 직접 입력 확인
    final RegExp phonePattern = RegExp(r'[\d-]{3,}');
    final match = phonePattern.firstMatch(command);
    if (match != null) {
      targetPhone = match.group(0)!.replaceAll('-', '');
      targetName = targetPhone;
    } else {
      // 2. 연락처 이름으로 검색
      targetName = _extractContactName(command);
      if (targetName != null) {
        await _speak("$targetName 연락처를 찾고 있어요.");
        targetPhone = await _findPhoneByName(targetName);
        if (targetPhone == null) {
          await _speak("$targetName 님의 연락처를 찾을 수 없어요.");
          return;
        }
      } else {
        await _speak("문자를 보낼 대상을 말씀해 주세요. 예: 엄마한테 문자 보내.");
        return;
      }
    }

    // 3. 명령에서 메시지 내용 추출 시도
    //    "엄마한테 보고싶다고 문자 보내" → "보고싶다"
    final msgContent = _extractSmsContent(command);
    if (msgContent != null && msgContent.isNotEmpty) {
      // 확인 단계로 이동
      _pendingSmsPhone = targetPhone;
      _pendingSmsName = targetName;
      _pendingSmsMessage = msgContent;
      await _speak("$targetName 님에게 '$msgContent' 라고 보낼까요?");
      await Future.delayed(const Duration(milliseconds: 1500));
      _listen();
    } else {
      // 메시지 내용이 없으면 2단계: 음성 입력 대기
      _pendingSmsPhone = targetPhone;
      _pendingSmsName = targetName;
      await _speak("$targetName 님에게 보낼 내용을 말씀해 주세요.");
      // 자동으로 음성 인식 시작
      await Future.delayed(const Duration(milliseconds: 1500));
      _listen();
    }
  }

  /// 명령에서 SMS 메시지 내용을 추출합니다.
  /// "엄마한테 보고싶다고 문자 보내" → "보고싶다"
  /// "엄마한테 내일 만나자고 문자 보내" → "내일 만나자"
  String? _extractSmsContent(String command) {
    // "~한테/에게 [메시지]고/라고 문자 보내" 패턴
    final RegExp contentPattern = RegExp(r'(?:한테|에게|께|에)\s+(.+?)(?:고|라고)\s*문자');
    final match = contentPattern.firstMatch(command);
    if (match != null) {
      return match.group(1)!.trim();
    }
    return null;
  }

  /// MethodChannel을 통해 SMS를 직접 전송합니다.
  Future<void> _sendSmsDirectly(String phone, String message, String displayName) async {
    try {
      const platform = MethodChannel('com.example.talk_recognition/tone');
      final result = await platform.invokeMethod('sendSms', {
        'phone': phone,
        'message': message,
      });
      if (result == true) {
        await _speak("$displayName 님에게 문자를 보냈습니다. 내용: $message");
      } else {
        await _speak("문자 전송에 실패했습니다.");
      }
    } catch (e) {
      print("DEBUG: SMS send error: $e");
      await _speak("문자 전송 중 오류가 발생했습니다. SMS 권한을 확인해 주세요.");
    }
  }

  // 앱 별칭 매핑
  static const Map<String, String> _appAliases = {
    '카톡': '카카오톡',
    '유트브': '유튜브',
    '인스타': '인스타그램',
  };

  Future<void> _processAppLaunchCommand(String command) async {
    String target = command.replaceAll('실행', '').replaceAll('열어', '').replaceAll('켜', '').replaceAll('해', '').trim();
    if (target.endsWith('을')) target = target.substring(0, target.length - 1);
    if (target.endsWith('를')) target = target.substring(0, target.length - 1);
    target = target.trim();

    if (target.isEmpty) return;

    // 별칭 적용
    if (_appAliases.containsKey(target)) {
      target = _appAliases[target]!;
    }

    print("DEBUG: Searching for app '$target'");
    
    // Fuzzy search in _apps
    Map<String, String>? bestMatch;
    // 1. Exact match
    try {
      bestMatch = _apps.firstWhere((app) => app['appName']!.toLowerCase() == target.toLowerCase());
    } catch (e) {
      // 2. Contains
      try {
        bestMatch = _apps.firstWhere((app) => app['appName']!.toLowerCase().contains(target.toLowerCase()));
      } catch (e) {
        // Not found
      }
    }

    if (bestMatch != null) {
      const platform = MethodChannel('com.example.talk_recognition/tone');
      try {
        final result = await platform.invokeMethod('launchApp', {'packageName': bestMatch['packageName']});
        if (result == true) {
          await _speak("${bestMatch['appName']}을 실행합니다.");
        } else {
          await _speak("앱을 실행할 수 없습니다.");
        }
      } catch (e) {
        await _speak("앱 실행 중 오류가 발생했습니다.");
      }
    } else {
      await _speak("$target 앱을 찾을 수 없습니다.");
    }
  }

  /// 카카오톡으로 메시지를 보내는 명령 처리
  /// "카톡으로 보고싶다고 보내" → 카카오톡 공유 인텐트로 메시지 전달
  Future<void> _processKakaoCommand(String command) async {
    // 메시지 내용 추출: "카톡으로 [XXX] 보내", "카톡으로 [XXX]라고 보내"
    String? message;
    final RegExp msgPattern = RegExp(r'(?:카톡|카카오톡)(?:으로|에|에서)?\s+(.+?)(?:고|\s*보내|라고|\s*전해)');
    final match = msgPattern.firstMatch(command);
    if (match != null) {
      message = match.group(1)?.trim();
    }

    if (message == null || message.isEmpty) {
      // 메시지 없이 그냥 카톡 실행
      await _speak("카카오톡을 엽니다.");
      const platform = MethodChannel('com.example.talk_recognition/tone');
      await platform.invokeMethod('launchApp', {'packageName': 'com.kakao.talk'});
      return;
    }

    // 메시지를 카카오톡 공유 인텐트로 전달
    try {
      const platform = MethodChannel('com.example.talk_recognition/tone');
      final result = await platform.invokeMethod('shareToApp', {
        'packageName': 'com.kakao.talk',
        'text': message,
      });
      if (result == true) {
        await _speak("카카오톡으로 '$message' 를 보냅니다. 대화 상대를 선택해 주세요.");
      } else {
        await _speak("카카오톡을 찾을 수 없습니다.");
      }
    } catch (e) {
      print("DEBUG: KakaoTalk share error: $e");
      await _speak("카카오톡 메시지 전송 중 오류가 발생했습니다.");
    }
  }

  /// 음성 계산기 — "일 더하기 일", "삼십 곱하기 이" 등
  Future<void> _processCalculation(String command) async {
    try {
      // 연산자 키워드를 기호로 치환
      String expr = command
          .replaceAll('더하기', ' + ')
          .replaceAll('플러스', ' + ')
          .replaceAll('빼기', ' - ')
          .replaceAll('마이너스', ' - ')
          .replaceAll('곱하기', ' * ')
          .replaceAll('곱셈', ' * ')
          .replaceAll('나누기', ' / ')
          .replaceAll('나눗셈', ' / ')
          .replaceAll('×', ' * ')
          .replaceAll('÷', ' / ')
          .replaceAll('은', '')
          .replaceAll('는', '')
          .replaceAll('얼마', '')
          .replaceAll('뭐', '')
          .replaceAll('?', '')
          .trim();

      // 기호 주변에 공백 추가 (붙어있을 경우 분리)
      expr = expr.replaceAllMapped(RegExp(r'(\d)([+\-*/])'), (m) => '${m[1]} ${m[2]} ');
      expr = expr.replaceAllMapped(RegExp(r'([+\-*/])(\d)'), (m) => ' ${m[1]} ${m[2]}');

      // 토큰으로 분리
      final tokens = expr.split(RegExp(r'\s+'));
      
      List<double> numbers = [];
      List<String> operators = [];
      
      for (final token in tokens) {
        if (token == '+' || token == '-' || token == '*' || token == '/') {
          operators.add(token);
        } else {
          final num = _parseKoreanNumber(token);
          if (num != null) {
            numbers.add(num);
          }
        }
      }

      if (numbers.length < 2 || operators.isEmpty) {
        await _speak("계산식을 이해하지 못했어요. '일 더하기 일' 처럼 말해주세요.");
        return;
      }

      // 순차적으로 계산
      double result = numbers[0];
      for (int i = 0; i < operators.length && i + 1 < numbers.length; i++) {
        switch (operators[i]) {
          case '+':
            result += numbers[i + 1];
            break;
          case '-':
            result -= numbers[i + 1];
            break;
          case '*':
            result *= numbers[i + 1];
            break;
          case '/':
            if (numbers[i + 1] == 0) {
              await _speak("0으로 나눌 수 없어요.");
              return;
            }
            result /= numbers[i + 1];
            break;
        }
      }

      // 결과 포맷팅 (정수면 소수점 제거)
      String resultStr;
      if (result == result.roundToDouble() && !result.isInfinite) {
        resultStr = result.toInt().toString();
      } else {
        resultStr = result.toStringAsFixed(2);
      }

      // 원래 명령 요약
      String summary = command
          .replaceAll('은', '').replaceAll('는', '')
          .replaceAll('얼마', '').replaceAll('뭐', '').replaceAll('?', '')
          .trim();
      
      // 히스토리에 결과 포함하여 기록
      _addToHistory("$summary = $resultStr");
      
      await _speak("$summary 은 $resultStr 입니다.");
    } catch (e) {
      print("DEBUG: Calculation error: $e");
      await _speak("계산 중 오류가 발생했어요.");
    }
  }

  Future<void> _saveMemo() async {
    if (_memoBuffer.isEmpty) {
      setState(() => _isMemoMode = false);
      await _speak("저장할 메모 내용이 없어요.");
      return;
    }

    try {
      // 다운로드 폴더에 저장 (앱 삭제해도 유지)
      final memoDir = Directory('/storage/emulated/0/Download/음성메모');
      if (!await memoDir.exists()) {
        await memoDir.create(recursive: true);
      }

      // 파일명: 메모_2026-02-16_01-21-06.txt (초 단위로 중복 방지)
      final now = DateTime.now();
      final fileName = '메모_${DateFormat('yyyy-MM-dd_HH-mm-ss').format(now)}.txt';
      final file = File('${memoDir.path}/$fileName');

      // 내용 작성
      final content = StringBuffer();
      content.writeln('📝 음성 메모');
      content.writeln('날짜: ${DateFormat('yyyy년 M월 d일 HH:mm').format(now)}');
      content.writeln('─' * 30);
      content.writeln('');
      for (final line in _memoBuffer) {
        content.writeln(line);
      }

      await file.writeAsString(content.toString());

      setState(() {
        _isMemoMode = false;
        _memoBuffer.clear();
      });

      _addToHistory('📝 메모 저장: $fileName');
      await _speak("저장완료");
      print("DEBUG: Memo saved to ${file.path}");
    } catch (e) {
      print("DEBUG: Memo save error: $e");
      setState(() => _isMemoMode = false);
      await _speak("메모 저장 중 오류가 발생했어요.");
    }
  }

  /// 한국어 숫자를 정수로 변환
  /// "일" → 1, "이십삼" → 23, "백오십" → 150, "천이백삼십사" → 1234
  double? _parseKoreanNumber(String text) {
    text = text.trim();
    if (text.isEmpty) return null;

    // 아라비아 숫자 시도
    final arabicNum = double.tryParse(text);
    if (arabicNum != null) return arabicNum;

    // 한국어 숫자 매핑
    const Map<String, int> digits = {
      '영': 0, '공': 0, '제로': 0,
      '일': 1, '하나': 1,
      '이': 2, '둘': 2,
      '삼': 3, '셋': 3,
      '사': 4, '넷': 4,
      '오': 5, '다섯': 5,
      '육': 6, '여섯': 6,
      '칠': 7, '일곱': 7,
      '팔': 8, '여덟': 8,
      '구': 9, '아홉': 9,
    };

    const Map<String, int> units = {
      '십': 10,
      '백': 100,
      '천': 1000,
      '만': 10000,
    };

    // 단순 단일 숫자
    if (digits.containsKey(text)) return digits[text]!.toDouble();

    // 복합 숫자 파싱: "이십삼", "백오십", "천이백삼십사"
    int result = 0;
    int current = 0;
    int i = 0;

    while (i < text.length) {
      bool matched = false;
      
      // 단위 체크 (긴 것부터)
      for (final entry in units.entries) {
        if (text.startsWith(entry.key, i)) {
          if (current == 0) current = 1; // "십" = 10, "백" = 100
          current *= entry.value;
          if (entry.value == 10000) {
            result += current;
            current = 0;
          }
          i += entry.key.length;
          matched = true;
          // 단위 다음에 숫자가 없으면 current를 result에 합산
          bool hasNextDigit = false;
          for (final d in digits.entries) {
            if (i < text.length && text.startsWith(d.key, i)) {
              hasNextDigit = true;
              break;
            }
          }
          bool hasNextUnit = false;
          for (final u in units.entries) {
            if (i < text.length && text.startsWith(u.key, i)) {
              hasNextUnit = true;
              break;
            }
          }
          if (!hasNextDigit && !hasNextUnit) {
            result += current;
            current = 0;
          }
          break;
        }
      }
      if (matched) continue;

      // 숫자 체크 (긴 것부터)
      bool digitMatched = false;
      // 긴 키부터 매칭 (여섯, 일곱 등)
      final sortedDigits = digits.entries.toList()
        ..sort((a, b) => b.key.length.compareTo(a.key.length));
      for (final entry in sortedDigits) {
        if (text.startsWith(entry.key, i)) {
          result += current;
          current = entry.value;
          i += entry.key.length;
          digitMatched = true;
          break;
        }
      }
      if (digitMatched) continue;

      // 매칭 실패 — 건너뜀
      i++;
    }

    result += current;
    return result > 0 ? result.toDouble() : null;
  }

  Future<void> _controlFlashlight(bool turnOn) async {
    try {
      final isTorchAvailable = await TorchLight.isTorchAvailable();
      if (isTorchAvailable) {
        if (turnOn) {
          await TorchLight.enableTorch();
          await _speak("불을 켰습니다.");
        } else {
          await TorchLight.disableTorch();
          await _speak("불을 껐습니다.");
        }
      } else {
        await _speak("이 기기에서는 손전등을 사용할 수 없어요.");
      }
    } on Exception catch (_) {
      await _speak("손전등 제어 중 에러가 발생했어요.");
    }
  }

  void _startAlarmSound() {
    if (_isAlarmRinging) return;
    
    setState(() {
      _isAlarmRinging = true;
      _alarmCount = 0;
      _text = "ALARM ACTIVE";
    });

    const platform = MethodChannel('com.example.talk_recognition/tone');

    _alarmTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
       if (_alarmCount >= 15) {
         _stopAlarmSound();
       } else {
         try {
           await platform.invokeMethod('playChime');
         } catch (e) {
           print("Error playing chime: $e");
           _speak("Ding Dong");
         }
         _alarmCount++;
       }
    });
  }

  void _stopAlarmSound() {
    _alarmTimer?.cancel();
    const platform = MethodChannel('com.example.talk_recognition/tone');
    platform.invokeMethod('stopChime').catchError((e) => print("Error stopping chime: $e"));

    _flutterTts.stop();
    setState(() {
      _isAlarmRinging = false;
      _text = "ALARM STOPPED";
    });
  }

  // ========== Bluetooth Classic (ESP32) ==========

  /// 페어링된 ESP32 찾아서 연결
  Future<void> _scanAndConnect() async {
    if (_isBleConnected) {
      _addToHistory('ℹ️ 이미 연결되어 있음');
      return;
    }
    if (_isScanning) return;

    setState(() {
      _isScanning = true;
      _bleStatus = '검색 중...';
    });
    _addToHistory('🔵 페어링된 ESP32 검색');

    try {
      // 권한 확인
      final btConnect = await Permission.bluetoothConnect.request();
      final btScan = await Permission.bluetoothScan.request();
      print('DEBUG: BT permissions - connect:$btConnect, scan:$btScan');

      if (!btConnect.isGranted) {
        _addToHistory('❌ 블루투스 권한 거부됨');
        setState(() { _isScanning = false; _bleStatus = '권한 필요'; });
        return;
      }

      // 블루투스 활성화 확인
      final isEnabled = await _bluetooth.isBluetoothEnabled();
      if (!isEnabled) {
        _addToHistory('❌ 블루투스 꺼져 있음');
        setState(() { _isScanning = false; _bleStatus = 'BT OFF'; });
        return;
      }

      // ★ 페어링된 디바이스 목록에서 ESP32 찾기
      final pairedDevices = await _bluetooth.getPairedDevices();
      print('DEBUG: ${pairedDevices.length} paired devices found');

      BluetoothDevice? esp32;
      for (final device in pairedDevices) {
        final name = device.name ?? '';
        _addToHistory('  📡 $name (${device.address})');
        print('DEBUG: Paired: $name (${device.address})');
        if (name.contains('ESP32') || name.contains('Controller')) {
          esp32 = device;
          _addToHistory('🔵 ★ 타겟 발견! $name');
        }
      }

      setState(() => _isScanning = false);

      if (esp32 == null) {
        _addToHistory('❌ ESP32 미발견 — 안드로이드 설정에서 먼저 페어링하세요');
        setState(() => _bleStatus = '미연결');
        return;
      }

      // 연결
      await _connectToDevice(esp32);

    } catch (e, stackTrace) {
      print('DEBUG: BT error: $e\n$stackTrace');
      _addToHistory('❌ BT 오류: $e');
      setState(() { _isScanning = false; _bleStatus = '오류'; });
    }
  }

  /// Bluetooth Classic 디바이스에 연결
  Future<void> _connectToDevice(BluetoothDevice device) async {
    try {
      setState(() => _bleStatus = '연결 중...');
      _addToHistory('🔵 연결 시도: ${device.name}');
      print('DEBUG: Connecting to ${device.address}...');

      // 기존 리스너 정리
      _connectionSubscription?.cancel();
      _connectionSubscription = null;
      _dataSubscription?.cancel();
      _dataSubscription = null;

      // ★ 먼저 연결 (리스너는 연결 성공 후에 등록!)
      final result = await _bluetooth.connect(device.address);
      print('DEBUG: Connect result: $result');

      if (result) {
        setState(() {
          _isBleConnected = true;
          _bleStatus = '연결됨';
        });
        _addToHistory('🟢 ESP32 연결 완료!');

        // ★ 연결 성공 후 잠시 대기 (BT 스택 안정화)
        await Future.delayed(const Duration(seconds: 1));

        // ★ 연결 상태 리스너 등록 (연결 후!)
        _connectionSubscription = _bluetooth.onConnectionChanged.listen((state) {
          print('DEBUG: BT connection state: connected=${state.isConnected}');
          // _isBleConnected가 true일 때만 해제 처리 (중복 방지)
          if (!state.isConnected && _isBleConnected) {
            setState(() {
              _isBleConnected = false;
              _bleStatus = '미연결';
              _isAdcMonitoring = false;
            });
            _addToHistory('🔴 ESP32 연결 해제');
          }
        });

        // ★ 데이터 수신 리스너
        _rxBuffer = '';
        _dataSubscription = _bluetooth.onDataReceived.listen((data) {
          _rxBuffer += data.asString();
          // 줄바꿈 단위로 완성된 메시지 처리
          while (_rxBuffer.contains('\n')) {
            final idx = _rxBuffer.indexOf('\n');
            final line = _rxBuffer.substring(0, idx).trim();
            _rxBuffer = _rxBuffer.substring(idx + 1);
            if (line.isNotEmpty) {
              _onDataReceived(line);
            }
          }
        });

      } else {
        setState(() => _bleStatus = '연결 실패');
        _addToHistory('❌ 연결 실패');
      }
    } catch (e) {
      print('DEBUG: BT connect error: $e');
      _addToHistory('⚠️ 연결 실패: $e');
      setState(() => _bleStatus = '연결 실패');
    }
  }

  /// Bluetooth 연결 해제
  Future<void> _disconnectBle() async {
    if (!_isBleConnected) {
      _addToHistory('ℹ️ 연결된 ESP32 없음');
      return;
    }
    try {
      _addToHistory('🔴 연결 해제 중...');
      await _bluetooth.disconnect();
      _connectionSubscription?.cancel();
      _connectionSubscription = null;
      _dataSubscription?.cancel();
      _dataSubscription = null;

      setState(() {
        _isBleConnected = false;
        _bleStatus = '미연결';
        _isAdcMonitoring = false;
      });
      _addToHistory('🔴 연결 해제 완료');
    } catch (e) {
      print('DEBUG: BT disconnect error: $e');
      setState(() {
        _isBleConnected = false;
        _bleStatus = '미연결';
      });
    }
  }

  /// 명령 전송 (Bluetooth Classic Serial)
  Future<void> _sendBleCommand(String cmd) async {
    if (!_isBleConnected) {
      await _speak('ESP32가 연결되어 있지 않아요.');
      return;
    }
    try {
      await _bluetooth.sendString('$cmd\n');
      print('DEBUG: BT sent: $cmd');
    } catch (e) {
      print('DEBUG: BT write error: $e');
      await _speak('명령 전송에 실패했어요.');
    }
  }

  /// ESP32에서 수신한 데이터 처리
  void _onDataReceived(String msg) {
    print('DEBUG: BT received: $msg');

    // GPIO 상태: "GPIO:1:ON,2:OFF,3:OFF,4:OFF"
    if (msg.startsWith('GPIO:')) {
      try {
        final payload = msg.substring(5);
        final parts = payload.split(',');
        final List<String> statusParts = [];
        for (final part in parts) {
          final kv = part.split(':');
          if (kv.length == 2) {
            final pin = int.tryParse(kv[0]);
            if (pin != null && pin >= 1 && pin <= 4) {
              final isOn = kv[1].trim().toUpperCase() == 'ON';
              setState(() {
                _pinStates[pin - 1] = isOn;
              });
              statusParts.add('CH$pin:${isOn ? "ON" : "OFF"}');
            }
          }
        }
        _addToHistory('📋 GPIO 상태: ${statusParts.join(", ")}');
      } catch (e) {
        print('DEBUG: GPIO parse error: $e');
      }
      return;
    }

    // ADC 값: "ADC:1:2048,2:1536"
    if (msg.startsWith('ADC:')) {
      try {
        final payload = msg.substring(4);
        final parts = payload.split(',');
        for (final part in parts) {
          final kv = part.split(':');
          if (kv.length == 2) {
            final ch = int.tryParse(kv[0]);
            final val = int.tryParse(kv[1]);
            if (ch != null && val != null && ch >= 1 && ch <= 2) {
              setState(() {
                _adcValues[ch - 1] = val;
              });
            }
          }
        }
      } catch (e) {
        print('DEBUG: ADC parse error: $e');
      }
      return;
    }

    // FUNC 응답: "FUNC:blink:ON", "FUNC:blink:OFF"
    if (msg.startsWith('FUNC:')) {
      if (msg.contains('blink:ON')) {
        setState(() => _isBlinking = true);
        _addToHistory('💡 LED 블링크 시작');
      } else if (msg.contains('blink:OFF')) {
        setState(() => _isBlinking = false);
        _addToHistory('⬛ LED 블링크 중지');
      } else {
        _addToHistory('📨 $msg');
      }
      return;
    }
  }

  /// "N번 켜/꺼" 음성 명령 매칭
  bool _matchEspPinCommand(String cmd) {
    final pattern = RegExp(r'(\d+|[일이삼사])\s*번\s*(켜|꺼)');
    final match = pattern.firstMatch(cmd);
    if (match != null) {
      int? pin;
      final numStr = match.group(1)!;
      pin = int.tryParse(numStr);
      if (pin == null) {
        const korDigits = {'일': 1, '이': 2, '삼': 3, '사': 4};
        pin = korDigits[numStr];
      }
      if (pin != null && pin >= 1 && pin <= 4) {
        final on = match.group(2) == '켜';
        _sendBleCommand('$pin:${on ? "ON" : "OFF"}');
        _speak('${pin}번 출력을 ${on ? "켰" : "껐"}습니다.');
        return true;
      }
    }
    return false;
  }

  /// "{name} 실행/시작/중지" 함수 호출 매칭
  bool _matchFuncCommand(String cmd) {
    final pattern = RegExp(r'(.+?)\s*(실행|시작|중지|멈춰|마쳐)');
    final match = pattern.firstMatch(cmd);
    if (match != null) {
      String name = match.group(1)!.trim();
      final action = match.group(2)!;
      // ESP/블루투스 등 시스템 키워드면 무시
      if (name.contains('esp') || name.contains('블루투스') || name.contains('센서') || name.contains('adc')) return false;
      if (name.contains('메모') || name.contains('알람') || name.contains('알림')) return false;

      if (action == '중지' || action == '멈춰' || action == '마쳐') {
        name = '${name}Stop';
      }
      // 한글 이름을 camelCase로 변환하지 않고 그대로 전송 (ESP32에서 매핑)
      _sendBleCommand('FUNC:$name');
      _speak('$name 기능을 실행합니다.');
      return true;
    }
    return false;
  }

  /// BLE 상태 인디케이터 위젯 + 연결/해제 버튼
  Widget _buildBleStatusBar() {
    const accentCyan = Color(0xFF00E5FF);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.3),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _isBleConnected ? accentCyan.withOpacity(0.5) : Colors.white12),
      ),
      child: Row(
        children: [
          Icon(
            Icons.bluetooth,
            color: _isBleConnected ? accentCyan : (_isScanning ? Colors.amber : Colors.white24),
            size: 16,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'ESP32: $_bleStatus',
              style: TextStyle(
                color: _isBleConnected ? accentCyan : Colors.white54,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          // 연결/해제 버튼
          if (_isScanning)
            const SizedBox(
              width: 16, height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2, color: Colors.amber,
              ),
            )
          else
            SizedBox(
              height: 28,
              child: TextButton(
                onPressed: _isBleConnected ? _disconnectBle : _scanAndConnect,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  backgroundColor: _isBleConnected
                      ? Colors.red.withOpacity(0.2)
                      : accentCyan.withOpacity(0.15),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6),
                    side: BorderSide(
                      color: _isBleConnected
                          ? Colors.redAccent.withOpacity(0.5)
                          : accentCyan.withOpacity(0.4),
                    ),
                  ),
                ),
                child: Text(
                  _isBleConnected ? '해제' : '연결',
                  style: TextStyle(
                    color: _isBleConnected ? Colors.redAccent : accentCyan,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }


  /// ESP32 Control Panel (GPIO + ADC + Functions)
  Widget _buildEsp32Panel() {
    if (!_isBleConnected) return const SizedBox.shrink();
    const accentCyan = Color(0xFF00E5FF);
    const accentOrange = Color(0xFFFF9100);
    const accentGreen = Color(0xFF69F0AE);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.4),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accentCyan.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ===== GPIO Section =====
          Row(
            children: [
              const Icon(Icons.power, size: 14, color: accentOrange),
              const SizedBox(width: 6),
              const Text('GPIO', style: TextStyle(
                color: accentOrange, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
              const Spacer(),
              // ALL ON / ALL OFF
              _miniButton('ALL ON', Colors.greenAccent, () {
                _sendBleCommand('ALL:ON');
              }),
              const SizedBox(width: 4),
              _miniButton('ALL OFF', Colors.redAccent, () {
                _sendBleCommand('ALL:OFF');
              }),
            ],
          ),
          const SizedBox(height: 8),
          // GPIO Toggle Row
          Row(
            children: List.generate(4, (i) {
              final isOn = _pinStates[i];
              return Expanded(
                child: GestureDetector(
                  onTap: () {
                    _sendBleCommand('${i + 1}:${isOn ? "OFF" : "ON"}');
                  },
                  child: Container(
                    margin: EdgeInsets.only(right: i < 3 ? 6 : 0),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    decoration: BoxDecoration(
                      color: isOn
                          ? accentGreen.withOpacity(0.15)
                          : Colors.white.withOpacity(0.05),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: isOn
                            ? accentGreen.withOpacity(0.5)
                            : Colors.white12,
                      ),
                    ),
                    child: Column(
                      children: [
                        Icon(
                          isOn ? Icons.flash_on : Icons.flash_off,
                          color: isOn ? accentGreen : Colors.white24,
                          size: 18,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'CH${i + 1}',
                          style: TextStyle(
                            color: isOn ? accentGreen : Colors.white38,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          isOn ? 'ON' : 'OFF',
                          style: TextStyle(
                            color: isOn ? accentGreen : Colors.white24,
                            fontSize: 9,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }),
          ),

          const SizedBox(height: 10),
          // ===== ADC Section =====
          Row(
            children: [
              const Icon(Icons.show_chart, size: 14, color: accentCyan),
              const SizedBox(width: 6),
              const Text('ADC', style: TextStyle(
                color: accentCyan, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
              const Spacer(),
              _miniButton(
                _isAdcMonitoring ? 'STOP' : 'START',
                _isAdcMonitoring ? Colors.redAccent : accentCyan,
                () {
                  if (_isAdcMonitoring) {
                    _sendBleCommand('ADC:STOP');
                    setState(() => _isAdcMonitoring = false);
                  } else {
                    _sendBleCommand('ADC:START');
                    setState(() => _isAdcMonitoring = true);
                  }
                },
              ),
            ],
          ),
          const SizedBox(height: 6),
          ...List.generate(2, (i) {
            final val = _adcValues[i];
            final voltage = (val / 4095.0 * 3.3).toStringAsFixed(2);
            final ratio = val / 4095.0;
            return Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  Text('CH${i + 1}', style: const TextStyle(
                    color: Colors.white54, fontSize: 10, fontFamily: 'monospace')),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: ratio,
                        backgroundColor: Colors.white12,
                        valueColor: AlwaysStoppedAnimation(accentCyan.withOpacity(0.7)),
                        minHeight: 6,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  SizedBox(
                    width: 38,
                    child: Text('$val', textAlign: TextAlign.right,
                      style: const TextStyle(
                        color: Colors.white70, fontSize: 10, fontFamily: 'monospace')),
                  ),
                  const SizedBox(width: 4),
                  SizedBox(
                    width: 38,
                    child: Text('${voltage}V', textAlign: TextAlign.right,
                      style: TextStyle(
                        color: accentCyan.withOpacity(0.8), fontSize: 10, fontFamily: 'monospace')),
                  ),
                ],
              ),
            );
          }),

          const SizedBox(height: 8),
          // ===== Function Buttons =====
          Row(
            children: [
              Icon(_isBlinking ? Icons.lightbulb : Icons.apps,
                size: 14, color: _isBlinking ? Colors.amberAccent : Colors.amberAccent.withOpacity(0.6)),
              const SizedBox(width: 6),
              Text(_isBlinking ? 'BLINK ON' : 'FUNC', style: TextStyle(
                color: _isBlinking ? Colors.amberAccent : Colors.amberAccent.withOpacity(0.6),
                fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
              const Spacer(),
              _actionButton(
                label: '💡 BLINK',
                color: Colors.amberAccent,
                isActive: _isBlinking,
                onTap: () {
                  _sendBleCommand('FUNC:blink');
                },
              ),
              const SizedBox(width: 4),
              _actionButton(
                label: '⬛ STOP',
                color: Colors.redAccent,
                isActive: false,
                onTap: () {
                  _sendBleCommand('FUNC:blinkStop');
                },
              ),
              const SizedBox(width: 4),
              _actionButton(
                label: '📋 STATUS',
                color: accentCyan,
                isActive: false,
                onTap: () {
                  _sendBleCommand('STATUS');
                  _addToHistory('📋 상태 요청...');
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _miniButton(String label, Color color, VoidCallback onTap) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        splashColor: color.withOpacity(0.3),
        highlightColor: color.withOpacity(0.15),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: color.withOpacity(0.12),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: color.withOpacity(0.4)),
          ),
          child: Text(label, style: TextStyle(
            color: color, fontSize: 9, fontWeight: FontWeight.bold)),
        ),
      ),
    );
  }

  Widget _actionButton({
    required String label,
    required Color color,
    required bool isActive,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        splashColor: color.withOpacity(0.4),
        highlightColor: color.withOpacity(0.2),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: isActive ? color.withOpacity(0.3) : color.withOpacity(0.1),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: isActive ? color : color.withOpacity(0.4),
              width: isActive ? 1.5 : 1,
            ),
            boxShadow: isActive ? [
              BoxShadow(color: color.withOpacity(0.4), blurRadius: 8, spreadRadius: 1),
            ] : null,
          ),
          child: Text(label, style: TextStyle(
            color: isActive ? Colors.white : color,
            fontSize: 9,
            fontWeight: FontWeight.bold)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // PiP 모드일 때 미니 UI
    if (_isInPipMode) {
      return Scaffold(
        body: GestureDetector(
          onTap: _listen,
          child: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFF0F2027), Color(0xFF2C5364)],
              ),
            ),
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    _isListening ? Icons.mic : Icons.mic_none,
                    color: _isListening ? const Color(0xFF00E5FF) : Colors.white54,
                    size: 48,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _isListening ? 'LISTENING' : 'TAP',
                    style: TextStyle(
                      color: _isListening ? const Color(0xFF00E5FF) : Colors.white38,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    // 일반 모드 UI
    const Color bgDark = Color(0xFF0F2027);
    const Color bgLight = Color(0xFF2C5364);
    const Color accentCyan = Color(0xFF00E5FF);
    const Color accentPurple = Color(0xFFBB86FC);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final shouldExit = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF1A1A2E),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: const BorderSide(color: Color(0xFF00E5FF), width: 1),
            ),
            title: const Text(
              '앱 종료',
              style: TextStyle(color: Color(0xFF00E5FF), fontSize: 18),
            ),
            content: const Text(
              '앱을 종료하시겠습니까?',
              style: TextStyle(color: Colors.white70, fontSize: 14),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('취소', style: TextStyle(color: Colors.white54)),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('종료', style: TextStyle(color: Color(0xFF00E5FF))),
              ),
            ],
          ),
        );
        if (shouldExit == true) {
          SystemNavigator.pop();
        }
      },
      child: Scaffold(
      body: TouchRippleEffect(
        child: Stack(
          children: [
            // 1. Background Gradient
            Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [bgDark, bgLight],
                ),
              ),
            ),
            
            // 2. Animated Elements (Background Circles)
            Positioned(
               top: -100,
               right: -100,
               child: Container(
                 width: 300,
                 height: 300,
                 decoration: BoxDecoration(
                   shape: BoxShape.circle,
                   color: accentPurple.withOpacity(0.1),
                   boxShadow: [
                     BoxShadow(color: accentPurple.withOpacity(0.2), blurRadius: 100, spreadRadius: 50),
                   ]
                 ),
               ),
            ),

            // 3. Main Content
            SafeArea(
              child: Column(
                children: [
                  // Header / History
                  Expanded(
                    flex: 3,
                    child: Padding(
                      padding: const EdgeInsets.all(20.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildBleStatusBar(),
                          Expanded(
                            child: ListView.builder(
                              itemCount: (_isBleConnected ? 1 : 0) + 1 + _history.length,
                              itemBuilder: (context, index) {
                                // Item 0: ESP32 Panel (only when connected)
                                if (_isBleConnected && index == 0) {
                                  return _buildEsp32Panel();
                                }

                                // Next item: COMMAND LOG header
                                final headerIndex = _isBleConnected ? 1 : 0;
                                if (index == headerIndex) {
                                  return const Padding(
                                    padding: EdgeInsets.only(bottom: 10),
                                    child: Text(
                                      "COMMAND LOG",
                                      style: TextStyle(color: Color(0xFF00E5FF), letterSpacing: 2.0, fontSize: 12),
                                    ),
                                  );
                                }

                                // History items
                                final historyIndex = index - headerIndex - 1;
                                if (historyIndex < 0 || historyIndex >= _history.length) {
                                  return const SizedBox.shrink();
                                }
                                final cmd = _history[historyIndex];
                                return Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 4.0),
                                  child: InkWell(
                                    onTap: () {
                                      if (cmd.contains('📄')) {
                                        _showMemoContent(cmd);
                                      } else {
                                        _processCommand(cmd);
                                      }
                                    },
                                    child: Container(
                                      padding: const EdgeInsets.all(10),
                                      decoration: BoxDecoration(
                                        color: Colors.black.withOpacity(0.3),
                                        border: Border(left: BorderSide(color: accentCyan.withOpacity(0.5), width: 2)),
                                      ),
                                      child: Text(
                                        "> $cmd",
                                        style: const TextStyle(color: Colors.white70, fontFamily: 'Courier', fontSize: 14),
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  // Active Area
                  Expanded(
                    flex: 4,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                         // Status Text
                         Text(
                           _status.toUpperCase(),
                           style: TextStyle(
                             color: _isListening ? accentCyan : Colors.grey,
                             letterSpacing: 2.0,
                             fontWeight: FontWeight.bold,
                           ),
                         ),
                         const SizedBox(height: 20),
                         
                         // Main Text Display with Glow
                         Container(
                           padding: const EdgeInsets.symmetric(horizontal: 30),
                           child: Text(
                             _text,
                             textAlign: TextAlign.center,
                             style: TextStyle(
                               color: Colors.white,
                               fontSize: 24,
                               fontWeight: FontWeight.w300,
                               shadows: [
                                 BoxShadow(
                                   color: accentCyan.withOpacity(0.8),
                                   blurRadius: 10,
                                   offset: const Offset(0, 0),
                                 ),
                               ],
                             ),
                           ),
                         ),
                         
                         const SizedBox(height: 50),

                         // Stop Alarm Button (Conditional)
                         if (_isAlarmRinging)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 20),
                              child: ElevatedButton.icon(
                                onPressed: _stopAlarmSound,
                                icon: const Icon(Icons.stop_circle_outlined),
                                label: const Text("STOP ALARM"),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.red.withOpacity(0.8),
                                  foregroundColor: Colors.white,
                                  side: const BorderSide(color: Colors.redAccent, width: 2),
                                  padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 15),
                                ),
                              ),
                            ),

                         // Mic Button with Pulse Animation
                         GestureDetector(
                           onTap: _listen,
                           child: AnimatedBuilder(
                             animation: _animationController,
                             builder: (context, child) {
                               return Container(
                                 width: 80,
                                 height: 80,
                                 decoration: BoxDecoration(
                                   shape: BoxShape.circle,
                                   color: _isListening ? accentCyan.withOpacity(0.2) : Colors.transparent,
                                   border: Border.all(
                                     color: _isListening ? accentCyan : Colors.white24,
                                     width: 2,
                                   ),
                                   boxShadow: _isListening ? [
                                     BoxShadow(
                                       color: accentCyan.withOpacity(0.5),
                                       blurRadius: 20 * _pulseAnimation.value,
                                       spreadRadius: 5 * _pulseAnimation.value,
                                     )
                                   ] : [],
                                 ),
                                 child: Icon(
                                   _isListening ? Icons.mic : Icons.mic_none,
                                   color: _isListening ? Colors.white : Colors.white54,
                                   size: 32,
                                 ),
                               );
                             },
                           ),
                         ),
                         
                         const SizedBox(height: 30),
                         const Text(
                           "TAP TO SPEAK",
                           style: TextStyle(color: Colors.white24, fontSize: 10, letterSpacing: 1.5),
                         ),
                      ],
                    ),
                  ),
                ],
               ),
             ),

             // 하단 실시간 시계
             Positioned(
               left: 0,
               right: 0,
               bottom: 20,
               child: Text(
                 _currentTime,
                 textAlign: TextAlign.center,
                 style: const TextStyle(
                   color: Colors.white,
                   fontSize: 48,
                   fontWeight: FontWeight.w200,
                   letterSpacing: 4,
                   fontFamily: 'monospace',
                   shadows: [
                     Shadow(
                       color: Color(0xFF00E5FF),
                       blurRadius: 20,
                     ),
                   ],
                 ),
               ),
             ),
           ],
        ),
      ),
    ),
    );

  }
}

class TouchRippleEffect extends StatefulWidget {
  final Widget child;
  const TouchRippleEffect({super.key, required this.child});
  @override
  _TouchRippleEffectState createState() => _TouchRippleEffectState();
}

class _TouchRippleEffectState extends State<TouchRippleEffect> with TickerProviderStateMixin {
  final List<Ripple> _ripples = [];

  void _addRipple(TapUpDetails details) {
    if (_ripples.length > 5) return; // Limit number of ripples

    final controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 1000));
    final ripple = Ripple(details.localPosition, controller);
    setState(() {
      _ripples.add(ripple);
    });
    controller.forward().then((_) {
      if (mounted) {
        setState(() {
          _ripples.remove(ripple);
        });
      }
      controller.dispose();
    });
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapUp: _addRipple,
      behavior: HitTestBehavior.translucent, // Allow taps to pass through if no child handles it? No, actually we want to catch taps on background.
      // But mic button and lists also need taps.
      // GestureDetector competes.
      // Solution: Listener?
      // Or Stack with IgnorePointer for ripples?
      // Better: Use Listener to get general taps but pass them down?
      // Actually standard GestureDetector with HitTestBehavior.translucent works well if children don't capture everything.
      // But List taps might be captured.
      // We will wrap the Stack.
      child: CustomPaint(
        foregroundPainter: RipplePainter(_ripples),
        child: widget.child,
      ),
    );
  }
}

class Ripple {
  final Offset position;
  final AnimationController controller;
  Ripple(this.position, this.controller);
}

class RipplePainter extends CustomPainter {
  final List<Ripple> ripples;
  RipplePainter(this.ripples) : super(repaint: Listenable.merge(ripples.map((r) => r.controller).toList()));

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    for (final ripple in ripples) {
      final progress = ripple.controller.value;
      final opacity = (1.0 - progress).clamp(0.0, 1.0);
      final radius = progress * 100.0;

      paint.color = const Color(0xFF00E5FF).withOpacity(opacity);
      canvas.drawCircle(ripple.position, radius, paint);
      
      // Secondary ring
      final radius2 = progress * 150.0;
      paint.color = const Color(0xFFBB86FC).withOpacity(opacity * 0.5);
      canvas.drawCircle(ripple.position, radius2, paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
