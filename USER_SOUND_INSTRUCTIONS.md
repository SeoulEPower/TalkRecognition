# 사용자 지정 알람 파일 설치 안내

사용자께서 제공해주시는 `wav` 파일을 이 앱에서 재생하도록 준비 작업을 마쳤습니다.

## 1. 현재 진행 상황
- `d:\AntiGravityProject\TalkRecognition\android\app\src\main\res\raw\alarm.wav` 경로에 임시 파일을 생성했습니다.
- 앱 코드를 수정하여 **이 파일명(alarm.wav)**을 자동으로 인식하고 재생하도록 만들었습니다.

## 2. 사용자 할 일
- 가지고 계신 **사운드 파일의 이름**을 `alarm.wav`로 변경해주세요. (확장자가 `.wav`여야 합니다.)
- 해당 파일을 `d:\AntiGravityProject\TalkRecognition\android\app\src\main\res\raw\` 폴더에 덮어써주세요.

## 3. 적용 방법
- 파일을 덮어쓴 후, `flutter run` 또는 앱 재시작을 하시면 새로운 소리가 적용됩니다.
- 만약 파일 경로를 알려주시면 제가 대신 복사해 드릴 수도 있습니다.
