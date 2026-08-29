SOOP 콘텐츠 메이커 - BUILD 13 고정 방 서버 (Render 테스트용)

목적
- 기존 PC의 server.ps1 + trycloudflare 임시 주소 대신
  Render에서 고정된 https://...onrender.com 주소로 방 API를 실행합니다.

구성
- server.ps1 : 기존 BUILD 13 방/프로필/빙고/후원 API
- Dockerfile : Render에서 PowerShell 서버 실행
- render.yaml : Render Web Service 설정
- .dockerignore

Render 설정
- Runtime: Docker
- Plan: Free (개발/호스팅 테스트용)
- Health Check Path: /api/health
- Render가 PORT 환경변수를 자동 제공합니다.

주의
- Free Render 서비스는 일정 시간 요청이 없으면 잠들 수 있습니다.
- Free 서버의 로컬 파일/메모리 상태는 재시작 시 유지되지 않을 수 있습니다.
- 따라서 이 패키지는 '고정 주소 + 기능 개발/테스트' 단계용입니다.
- 실제 출시 전에는 DB 기반 영구 저장과 항상 켜진 서버 플랜으로 바꾸는 것이 안전합니다.

다음 단계
1) 이 폴더의 파일들을 GitHub 저장소에 올립니다.
2) Render에서 Web Service를 만들고 그 저장소를 연결합니다.
3) 배포 완료 후 https://xxxx.onrender.com/api/health 가 ok:true인지 확인합니다.
4) 그 고정 주소를 SOOP 호스팅용 화면 파일의 API 주소로 연결합니다.
