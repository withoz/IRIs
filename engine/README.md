# engine/ — RTXPT 포크 관리

IRIS의 렌더링 코어는 [NVIDIA RTXPT](https://github.com/NVIDIA-RTX/RTXPT)의 포크입니다.
**이 디렉터리에 엔진 소스는 없습니다.** 여기 있는 것은 포크를 재현하기 위한 정보뿐입니다.

## 왜 소스를 저장소에 넣지 않는가

| | 크기 |
|---|---|
| RTXPT 전체 체크아웃 | **12 GB** |
| ├ `Assets/` (NVIDIA 테스트 씬) | 4.9 GB |
| ├ `.git` | 5.3 GB |
| ├ `External/` (의존성 8종 + 다운로드 패키지) | 707 MB |
| └ **`Rtxpt/` — 실제 앱 소스** | **3.1 MB** |

12 GB 중 우리가 손대는 것은 3.1 MB이고, 그중에서도 일부입니다.
전체를 복제하면 저장소가 못 쓰게 되고, 상위 갱신을 따라가기도 어려워집니다.

**대신 이렇게 나눕니다.**

| 무엇 | 어디 | 추적 |
|---|---|---|
| IRIS 고유 코드 (프로토콜 수신부, 씬 브리지, 조명, UI) | `src/` | ✅ 저장소 |
| 엔진에 가하는 수정분 | `engine/patches/*.patch` | ✅ 저장소 |
| 상위 고정 정보 | `engine/UPSTREAM.lock` | ✅ 저장소 |
| NVIDIA 원본 트리 | `%IRIS_ENGINE_DIR%` (기본 `E:\iris-ext\RTXPT`) | ❌ 외부 |

**엔진 수정분이 패치로 저장소에 들어가므로 작업은 전부 보존됩니다.**
동시에 NVIDIA 코드는 우리 히스토리에 들어가지 않고, 상위 버전을 올릴 때는
`UPSTREAM.lock` 을 갱신하고 패치를 리베이스하면 됩니다.

> 이 구조는 라이선스 측면에서도 맞습니다. NVIDIA RTX SDKs LICENSE는 앱이 SDK를
> 넘어서는 **실질적 추가 기능**을 가질 것을 요구합니다. `src/` 가 그 기능이고,
> 경계가 디렉터리로 드러납니다. 상세는 [docs/06-Phase1-계획.md](../docs/06-Phase1-계획.md) 2절.

## 사용법

```powershell
# 1. 새 머신에서 엔진 포크를 만든다 (약 12 GB, 시간이 걸립니다)
tools\setup\bootstrap_engine.ps1

# 2. 작업 중 — 엔진을 고쳤으면 패치로 뽑아 저장소에 커밋한다
tools\setup\export_engine_patches.ps1

# 3. 다른 머신에서 그 수정분을 받는다
tools\setup\apply_engine_patches.ps1
```

`IRIS_ENGINE_DIR` 환경변수로 엔진 경로를 바꿀 수 있습니다.

## 브랜치 규약

| 브랜치 | 뜻 |
|---|---|
| `upstream/main` | NVIDIA 원본. **직접 커밋하지 않습니다** |
| `iris/main` | 우리 포크. 모든 엔진 수정이 여기 쌓입니다 |

`git remote` 에서 `upstream` 이 NVIDIA입니다. `origin` 은 없습니다 —
포크를 원격에 올릴지는 아직 정하지 않았습니다.
