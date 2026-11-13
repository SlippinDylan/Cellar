<div align="center">
  <img src="images/readme/app-icon.png" width="160" height="160" alt="Cellar 앱 아이콘">
  <h1>Cellar</h1>
  <p>하나의 네이티브 앱에서 Mac의 개발 도구를 관리하세요.</p>
  <p>
    <a href="../README.md">English</a> ·
    <a href="README.zh-CN.md">简体中文</a> ·
    <a href="README.zh-TW.md">繁體中文</a> ·
    <a href="README.ja.md">日本語</a> ·
    <strong>한국어</strong> ·
    <a href="README.de.md">Deutsch</a> ·
    <a href="README.fr.md">Français</a> ·
    <a href="README.es.md">Español</a>
  </p>
</div>

Cellar는 Homebrew 소프트웨어, npm 전역 패키지, Node.js 버전 및 터미널 설정을 하나의 macOS 앱에 모았습니다. 설치된 소프트웨어를 확인하고, 필요한 도구를 찾고, 업데이트하며, 제거하기 전에 어떤 항목이 삭제되는지 검토할 수 있습니다.

> [!NOTE]
> Cellar 1.0은 아직 공개 출시되지 않았습니다. 다운로드할 수 있는 설치 파일이나 Homebrew Cask는 아직 없습니다. 소스에서 빌드할 수 있으며, 실제 환경과 UI에 대한 인수 검증은 아직 남아 있습니다.

## 주요 기능

| 작업 | Cellar에서 할 수 있는 일 |
|---|---|
| 환경 상태 확인 | 홈에서 Homebrew, Node.js, npm, nvm 및 터미널 상태를 확인합니다. |
| 설치된 소프트웨어 관리 | 소프트웨어 보관함에서 Homebrew Formula, Cask 및 npm 전역 패키지를 살펴보고 검색하거나 필터링합니다. 개별 항목이나 필터링한 항목을 일괄 업데이트하고, 개별 항목을 제거합니다. |
| 새로운 도구 찾기 | 탐색에서 Homebrew와 npm을 검색하고, 개별 항목 또는 같은 패키지 유형의 항목을 일괄 설치합니다. |
| 개발 환경 설정 | nvm을 통한 Node.js 버전, 선택한 프로젝트의 `.nvmrc`, Homebrew Tap, npm 레지스트리, Oh My Zsh 테마 및 플러그인을 관리합니다. |
| 검사 및 정리 | Homebrew 진단과 npm 캐시 검증을 실행하고, 지원되는 캐시·사용하지 않는 Node 버전·이전 Manager 로그 정리 작업을 검토합니다. |

페이지를 이동해도 작업 진행 상황과 최근 결과가 계속 표시됩니다. 일괄 작업이 일부만 성공한 경우에도 개별 결과를 확인할 수 있습니다.

인터페이스는 **영어, 중국어 간체, 중국어 번체, 일본어, 한국어, 독일어, 프랑스어 및 스페인어**를 지원합니다. 기본값은 **시스템 설정 따르기**입니다. 설정 > 일반에서 언어를 선택할 수 있으며, 언어를 변경하면 Cellar가 재시작됩니다.

## 시스템 요구 사항 및 출시 상태

- **Apple Silicon Mac**(`arm64`)에서 **macOS 26 이상**이 필요합니다.
- 소스에서 빌드하려면 **Xcode 26 이상**이 필요합니다.
- Homebrew, Node.js, npm 및 nvm은 Cellar가 관리하는 도구이며 앱에 포함되어 있지 않습니다.

Command Line Tools 또는 Homebrew가 없는 경우 Cellar에서 시스템 설치 절차를 열 수 있습니다. Homebrew 공식 설치 패키지는 열기 전에 검증합니다. nvm은 설치 안내를 제공합니다.

앱 업데이트는 공유 [Homebrew Tap](https://github.com/SlippinDylan/homebrew-tap)을 통해 Sparkle을 사용하도록 설정되어 있습니다. 해당 버전의 첫 릴리스에서 서명된 업데이트 피드와 Cask가 생성됩니다. Debug 및 일반 로컬 빌드에서는 앱 업데이트가 비활성화됩니다.

## 소스에서 빌드

```bash
git clone https://github.com/SlippinDylan/Cellar.git
cd Cellar
open Cellar.xcodeproj
```

Xcode에서 **Cellar** 스킴, **My Mac**, **Debug** 구성을 선택한 다음 **⌘R**을 누르세요. Debug는 로컬 임시 서명(Sign to Run Locally)을 사용하므로 Apple 개발자 계정에 로그인하거나 서명 인증서를 설치할 필요가 없습니다.

명령줄에서도 빌드할 수 있습니다.

```bash
xcodebuild build \
  -project Cellar.xcodeproj \
  -scheme Cellar \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData-Debug
```

빌드된 앱은 `build/DerivedData-Debug/Build/Products/Debug/Cellar.app`에 있습니다. 테스트, 서명 및 릴리스 빌드는 [개발 가이드](development.md)를 참고하세요.

## 환경을 변경하기 전에

- npm 전역 패키지는 특정 Node.js 설치에 속합니다. 검색과 작업은 선택한 Node 환경을 사용하며, Cellar는 프로젝트 내부의 npm 의존성을 관리하지 않습니다.
- Cellar가 사용하는 Node 버전을 전환하면 현재 Cellar 세션에만 적용되며, 이미 열린 터미널에는 적용되지 않습니다. 프로젝트의 `.nvmrc`를 저장하면 필요한 버전만 선언됩니다. Node를 자동으로 설치하거나 터미널의 Node 버전을 전환하지 않습니다.
- 소프트웨어 보관함과 탐색 페이지의 카드에서 개별 패키지를 설치하거나 업데이트하면 바로 시작됩니다. 터미널 구성 요소 설치, 일괄 작업, 제거, 정리 및 설정 변경은 먼저 적용 범위를 확인합니다. 실행 중인 작업은 수동으로 중단할 수 없으며, 작업이 진행 중이면 Cellar를 종료할 수 없습니다.
- Homebrew Cask를 제거할 때는 사전에 확인하고 대상에 속한다고 검증할 수 있는 관련 데이터도 삭제할 수 있습니다. 공유되거나 검증되지 않은 데이터는 유지됩니다. Formula 및 npm 제거에는 이러한 관련 데이터 정리가 포함되지 않습니다. Cellar는 Homebrew cleanup을 실행하거나 더 이상 필요하지 않은 의존성을 자동으로 제거하지 않습니다.
- 일부 잔여 파일을 정리하려면 macOS 관리자 인증 또는 전체 디스크 접근 권한이 필요합니다. 암호는 macOS에서 처리하며, Cellar는 암호를 수집하거나 상주하는 특권 서비스를 설치하지 않습니다. 권한을 부여해도 모든 파일이 삭제되는 것은 아닙니다.
- 작업은 일부만 성공할 수 있습니다. Cellar는 완료 및 실패 항목을 보고하며, 롤백을 보장하지 않습니다. `.zprofile`을 수정하거나 로그인 셸을 변경하지 않습니다.

## 데이터 및 네트워크

Cellar에는 계정, 원격 측정 또는 자체 백엔드가 없습니다. 도구 조회, 검색, 설치, 플러그인 및 앱 업데이트는 공식 서비스 또는 사용자가 설정한 소스에 접속합니다. Homebrew와 npm 조회 시 각 도구의 캐시에 데이터가 기록될 수도 있습니다.

공식 Homebrew Cask 아이콘은 [CaskFlow](https://github.com/alielsokary/CaskFlow)에서 제공하며 `cdn.jsdelivr.net`을 통해 가져옵니다. CDN은 요청한 Cask 식별자와 일반적인 연결 정보를 받습니다. CaskFlow의 MIT 라이선스는 앱에 포함되며, 소프트웨어 로고의 권리는 각 소유자에게 있습니다.

| 로컬 데이터 | 위치 |
|---|---|
| 앱에 포함된 Manager의 실행용 복사본 | `~/Library/Application Support/Cellar/Managers/<version>/` |
| 로그 | `~/Library/Logs/Cellar/` |
| 다운로드한 소프트웨어 아이콘 | `~/Library/Caches/com.dylanwang.Cellar/CatalogIcons/` |

로그 수준과 보관 기간은 설정 > 일반에서 변경할 수 있습니다. 파일 로그에는 원시 명령이나 stdout/stderr가 저장되지 않습니다. 작업 결과는 현재 세션에서만 유지됩니다.

## 문서

상세 프로젝트 문서는 현재 중국어로 제공됩니다. [문서 색인](README.md), [제품 요구 사항](requirements/product-requirements.md), [아키텍처](architecture/macos-app-architecture.md), [개발 가이드](development.md), [수동 인수 검증 목록](manual-smoke-checklist.md)을 참고하세요.
