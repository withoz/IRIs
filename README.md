# iris

AEC용 실시간 렌더링 프로그램. Enscape 계열의 CAD/BIM 연동 실시간 렌더러를 목표로 합니다.

## 문서

| 문서 | 용도 |
|---|---|
| **[docs/00-진행상황.md](docs/00-진행상황.md)** | **여기부터 읽으세요.** 현재 위치, 미결정 사항, 다음 할 일 |
| [docs/01-실시간렌더러-오픈소스-자료집.md](docs/01-실시간렌더러-오픈소스-자료집.md) | 오픈소스 SDK·라이브러리·학습자료 종합 자료집 (링크 112개) |
| [docs/02-Enscape-아키텍처-분석.md](docs/02-Enscape-아키텍처-분석.md) | 시장 1위의 실제 구현. 자료집 권장 경로와의 모순 |
| [docs/03-자사엔진-현황과-접점.md](docs/03-자사엔진-현황과-접점.md) | AXiA3D·axia-sketch 현황 + IRIS 접점 옵션 |
| [docs/04-RTXPT-실측.md](docs/04-RTXPT-실측.md) | RTXPT 빌드·성능·품질 실측. 실제 SketchUp 모델 렌더 |
| [docs/05-씬-델타-프로토콜.md](docs/05-씬-델타-프로토콜.md) | 라이브 링크 프로토콜 설계 초안 |
| [docs/실시간렌더러-자료집.html](docs/실시간렌더러-자료집.html) | 01번 문서의 단독 실행 HTML (열람·공유용) |
| [tools/sketchup/](tools/sketchup/) | SketchUp 라이브 링크 프로브 + 실측 결과 |

## 현재 상태

**미결정 5개 전부 확정** (2026-09-07) — SketchUp 전용 · RTX 전용 · 경로 B · 클로즈드 상용 · Windows 전용.
**개발 환경 구축 완료** (VS 2022/2026 C++ · CMake · Ninja · Windows SDK · Vulkan SDK 1.4.357.0).

Phase 0 기술 검증 4종 중 **과제 4(SketchUp 라이브 링크) 완료**, **과제 2(RTXPT) 빌드·성능 실측 완료**.
자세한 내용은 [docs/00-진행상황.md](docs/00-진행상황.md) 참조.

## 개발 환경

| 머신 | 사양 | 경로 | 담당 |
|---|---|---|---|
| WyoungK | Ultra 7 265KF · 32GB · **RTX 5060 Ti 16GB** | `E:\IRIS` | **주 개발기.** 렌더링(RT 스택 빌드·테스트) + SketchUp 2026 플러그인 |
| AI-00-002 | i7-8700 · 16GB · GTX 1060 6GB | `D:\iris` | 참조·검증용. Enscape 2.5/3ds Max 동작 관찰, 구형 GPU 폴백 테스트 |

두 머신 모두 이 저장소를 통해 동기화합니다.
