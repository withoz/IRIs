# RTXPT 실측 — Phase 0-2 과제 2

> 측정일: 2026-09-07 · WyoungK (RTX 5060 Ti 16GB, 드라이버 610.74)
> RTX Path Tracing **v1.8.1 (D3D12)** · 출력 3840×2036, 내부 2227×1181 (DLSS Balanced)
> VSync 비활성 · `ENABLE_DEBUG_VIZUALISATIONS: 1` (컴파일 타임 상수, 전 측정 동일)

---

## 요약

1. **RTXPT는 5060 Ti에서 돕니다.** 실내 씬 기준 28~31 ms (32~35 FPS) @ 4K
2. **자료집 권장 파이프라인(ReSTIR + NRD)이 기본값(DLSS-RR)보다 1.4~1.6배 느립니다**
3. **광원 수는 성능에 영향이 없습니다** — 1개 → 1,025개로 늘려도 측정 오차 수준
4. → **자료집 5장의 권장 조합과 4.1의 RTXDI 전제를 재검토해야 합니다**

---

## 1. 빌드

| 항목 | 값 |
|---|---|
| 저장소 | `https://github.com/NVIDIA-RTX/RTXPT` @ `f08d1c7` |
| 로컬 경로 | `E:\iris-ext\RTXPT` (IRIS 저장소 **바깥**) |
| 크기 | 9.9 GB (서브모듈 8개 포함) |
| 제너레이터 | Visual Studio 17 2022, x64 |
| configure | 47.4초 |
| 산출물 | `bin/Rtxpt.exe` 7.3 MB, 셰이더 blob 295개 |

configure가 자동으로 받아온 스택 — 자료집 4~7장의 목록이 한 번에 딸려옵니다.

| 구성요소 | 버전 |
|---|---|
| Agility SDK | 1.619.0 |
| Streamline | v2.9.0 |
| NRD | v4.15.2 |
| OMM SDK | 1.8.0 |
| NVAPI · DLSS(SR/RR/FG) | 포함 |

### 1.1 빌드에서 막힌 것 — 한글 Windows 고유 문제

**CMake 4 호환성 문제는 발생하지 않았습니다.** `VERSION 2.8`·`3.4` 선언이 있으나
전부 `cxxopts/test/`·`glfw`·`imgui/examples/` 등 빌드 경로 밖이라 CMake가 하강하지
않습니다. 회피책(`-DCMAKE_POLICY_VERSION_MINIMUM=3.5`)은 쓸 일이 없었습니다.

대신 **두 가지 환경 문제**가 있었습니다. 둘 다 nvpro-samples·NRD-Sample에서 재현될
가능성이 높습니다.

| 증상 | 원인 | 조치 |
|---|---|---|
| `glfw3.h` 에서 `warning C4819` → `error C2220` | **한글 로케일(CP949).** MSVC가 UTF-8 소스의 비ASCII 주석(GLFW 관리자 이름 등)을 코드페이지 949로 읽으려다 실패. GLFW는 경고를 오류로 처리 | 컴파일 플래그에 `-utf-8` |
| `error C1083: 'C:/Program' 을 열 수 없습니다` | **Git Bash 경로 변환.** MSYS가 `/utf-8`을 `C:/Program Files/Git/utf-8`로 번역 | 대시 형식 `-utf-8` + `MSYS_NO_PATHCONV=1` |

### 1.2 ⚠ CMAKE_*_FLAGS 를 덮어쓰지 마십시오

`-DCMAKE_CXX_FLAGS=-utf-8` 처럼 설정하면 **CMake의 MSVC 기본 플래그가 통째로
사라집니다.** 이것 때문에 두 번 더 실패했습니다.

- `/EHsc` 유실 → `warning C4530` → ShaderMake 빌드 실패
- 없던 `/W3` 추가 → 경고 수준 상승 → `/WX`가 걸린 RtxptCore에서 C4244 등 51건 발생

동작한 설정 (CMake 4의 실제 기본값 + utf-8. CMP0092에 따라 **`/W3` 없음**):

```bash
export MSYS_NO_PATHCONV=1
cmake -S . -B build -G "Visual Studio 17 2022" -A x64 \
  -DCMAKE_C_FLAGS="-DWIN32 -D_WINDOWS -utf-8" \
  -DCMAKE_CXX_FLAGS="-DWIN32 -D_WINDOWS -EHsc -utf-8"
cmake --build build --config Release --parallel
```

**더 안전한 대안**: `CMAKE_*_FLAGS`를 건드리지 않고 `CL` 환경변수로 `-utf-8`만
주입하면 CMake의 기본값 관리에 손대지 않아도 됩니다. 다음 프로젝트에서는 이 쪽을
먼저 시도하십시오.

> 빌드 로그는 **반드시 파일로 온전히** 받으십시오. `cmake --build ... | tail -60`으로
> 파이프하면 파이프라인 종료 코드가 `tail`의 것이 되어 **cmake 실패가 가려집니다.**
> 실제로 이것 때문에 "빌드 성공"으로 오판했습니다.

---

## 2. 성능 실측

### 2.1 파이프라인 A — DLSS-RR (RTXPT v1.8.1 기본값)

DLSS Ray Reconstruction이 디노이징과 업스케일을 겸합니다. ReSTIR는 사용 불가(3절 참조).

| 씬 | 성격 | 광원 | MAT | MESH | 인스턴스 | ms | FPS |
|---|---|---|---|---|---|---|---|
| bistro | **실외** 거리 | 71 | 411 | 766 | 3,277 | 40.8~44.5 | 22.5~24.5 |
| kitchen | **실내** 주방 | 1 | 67 | 741 | 765 | 31.406 | 31.8 |
| kitchen-lights-256 | 실내 + 다운라이트 | 257 | 67 | 741 | 765 | 31.377 | 31.9 |
| kitchen-lights-1024 | 실내 + 다운라이트 | 1,025 | 67 | 741 | 765 | 31.435 | 31.8 |
| living-room | **실내** 거실 | 1 | 39 | 150 | 150 | 28.172 | 35.5 |

### 2.2 파이프라인 B — DLSS(SR) + NRD + ReSTIR DI + ReSTIR GI

자료집 5장이 권장한 조합입니다.

| 씬 | 광원 | ms | FPS | A 대비 |
|---|---|---|---|---|
| bistro | 71 | 66.611 | 15.0 | **1.56× 느림** |
| kitchen | 1 | 43.740 | 22.9 | 1.39× 느림 |
| kitchen-lights-256 | 257 | 43.750 | 22.9 | 1.39× 느림 |
| kitchen-lights-1024 | 1,025 | 43.970 | 22.7 | 1.40× 느림 |
| living-room | 1 | 39.245 | 25.5 | 1.39× 느림 |

참고: living-room에서 **ReSTIR GI만** 켠 중간값 = 33.0 ms (30.3 FPS)

### 2.3 해상도 영향

| 출력 해상도 | 씬 | 파이프라인 | ms | FPS |
|---|---|---|---|---|
| 2560×1440 | bistro | A | 19.633 | 50.9 |
| 3840×2036 | bistro | A | 40.8~44.5 | 22.5~24.5 |

**해상도가 지배적 변수입니다.** 자료집 기준선 16.6 ms(60fps)는 4K에서 어떤 조합으로도
달성하지 못했고, 1440p에서는 근접합니다.

---

## 3. ReSTIR가 기본값에서 잠겨 있는 이유

RTXPT v1.8.1은 **DLSS-RR 선택 시 ReSTIR DI/GI를 UI에서 비활성화**합니다.

```cpp
// Rtxpt/SampleUI.cpp:955
bool disabled = !m_ui.UseNEE || (m_ui.RealtimeAA==3 && m_ui.DisableReSTIRsWithDLSSRR);
```

NVIDIA 자신의 툴팁 원문:

> "ReSTIR DI (RTXDI) requires Next Event Estimation to be enabled
> **and this implementation is currently not tuned to work with DLSS-RR**"
>
> "ReSTIR GI (RTXDI) **is currently not tuned to work well with DLSS-RR**.
> Use middle mouse button to enable anyway"

AA 선택지는 `{ Disabled, TAA, DLSS, DLSS-RR }`이며, **DLSS(SR)로 바꾸면 NRD와
ReSTIR GI가 자동으로 켜집니다.** 즉 두 파이프라인은 양자택일 구조입니다.

**v1.8.1의 기본값이 DLSS-RR이라는 사실이 시사적입니다** — NVIDIA가 미는 조합이
자료집 작성 시점과 달라졌을 가능성이 높습니다.

---

## 4. 다광원 검증 — 자료집 전제의 반증

### 4.1 왜 별도로 만들었나

자료집 4.1은 RTXDI를 *"수천~수십만 광원 실시간 처리의 핵심 — 건축 실내 조명에 결정적"*
이라고 적었습니다. 그런데 RTXPT 기본 씬은 해석적 광원이 최대 71개(bistro)뿐이라
그 조건을 재볼 수 없습니다. 실제 건축 실내는 다운라이트가 수백 개입니다.

[`tools/rtxpt/gen_light_scene.py`](../tools/rtxpt/gen_light_scene.py)로 kitchen 씬에
천장 다운라이트를 격자로 깔아 64/256/1024개 씬을 생성했습니다. 총 광량을 광원 수에
반비례시켜 밝기를 일정하게 유지했습니다.

### 4.2 결과 — 광원 수는 성능에 영향이 없습니다

| 광원 수 | 파이프라인 A (DLSS-RR) | 파이프라인 B (ReSTIR) |
|---|---|---|
| 1 | 31.406 ms | 43.740 ms |
| 257 | 31.377 ms | 43.750 ms |
| 1,025 | 31.435 ms | 43.970 ms |
| **1 → 1,025 증감** | **+0.09%** | **+0.5%** |

**1개에서 1,025개로 늘려도 측정 오차 수준입니다.** ReSTIR는 광원 수와 무관하게
일관되게 ~39% 느립니다.

---

## 5. 이 수치의 한계 — 반드시 함께 읽으십시오

**① 품질을 비교하지 않았습니다. 이것이 가장 큰 한계입니다.**
패스트레이서를 비교하는 옳은 기준은 프레임 시간이 아니라 **"허용 가능한 노이즈에
도달하는 시간"**입니다. ReSTIR의 본질은 분산 감소이므로, 같은 노이즈 수준에서
비교하면 결과가 뒤집힐 수 있습니다. 위 수치는 오직 ms만 잰 것입니다.

**② 제 테스트 광원은 광원 샘플링에 가장 쉬운 조건입니다.**
균일 격자, 동일 강도, 동일 색. NEE는 총 광원 수와 무관하게 바운스당 몇 개만
샘플링하므로 이런 균질한 배치에서는 개수가 늘어도 비용이 늘지 않습니다.
**ReSTIR가 필요한 진짜 조건은 개수가 아니라 기여도 편차와 가림(occlusion)입니다** —
강도가 제각각이고, 대부분 가려져 있고, 일부만 지배적인 배치. 그 조건은 아직
안 만들어봤습니다.

**③ 디버그 시각화가 켜진 상태입니다.** `ENABLE_DEBUG_VIZUALISATIONS`는 컴파일 타임
상수(`Config.h:63`)라 끄려면 재빌드가 필요합니다. 전 측정에 동일하게 적용됐으므로
**비교는 유효하나 절대값은 부풀려져** 있습니다. 하위 항목(delta tree, RTXDI viz)은
이미 0이라 비용은 크지 않을 것으로 보이나 확인하지 않았습니다.

**④ 조건당 1회 관측**이며 bistro는 40.8~44.5 ms로 흔들렸습니다.

---

## 6. 프로젝트에 대한 함의

**① 경로 B는 성립합니다.** 보급형 5060 Ti에서 실내 4K 32~35 FPS, 1440p 50 FPS입니다.
RTX 전용 확정([00-진행상황.md](00-진행상황.md) ③)의 첫 실측 뒷받침입니다.

**② 자료집 5장의 권장 조합을 재검토해야 합니다.** `ReSTIR DI + NRD + DLSS`가
현재 RTXPT 기본값보다 느리고, NVIDIA 자신이 DLSS-RR을 기본으로 두고 있습니다.
다만 5절 ①의 품질 한계 때문에 **아직 결론이 아니라 의문 제기 단계**입니다.

**③ 자료집 4.1의 RTXDI 전제는 우리 조건에서 확인되지 않았습니다.**
"건축 실내 조명에 결정적"이라는 근거가 광원 개수라면, 1,025개까지는 그렇지 않습니다.

**④ 실내가 실외보다 빠릅니다.** kitchen·living-room이 bistro보다 30% 이상 빠릅니다.
주 용도가 실내라는 점에서 유리합니다. 다만 **실외 조감도·배치도도 제품 범위**이므로
bistro급(인스턴스 3,277) 성능도 함께 관리해야 합니다.

**⑤ 4K 60fps는 현재 미달입니다.** 최선이 28.2 ms(35.5 FPS)입니다. 1440p 기준으로
목표를 잡거나, 디버그 빌드 정리·프리셋 조정으로 여유를 확보해야 합니다.

---

## 7. 다음 검증 항목

1. **동일 노이즈 기준 비교** — 5절 ①. 두 파이프라인의 수렴 속도를 같은 품질 기준에서
   재야 파이프라인 판단이 확정됩니다
2. **디버그 시각화 끈 재빌드** — 순수 렌더 비용 확인
3. **불균질 다광원** — 강도 편차 + 가림이 큰 배치. ReSTIR의 실제 값어치가 드러나는 조건
4. **자체 IFC/SketchUp 모델 로드** — 과제 2의 원래 목표 중 남은 절반
