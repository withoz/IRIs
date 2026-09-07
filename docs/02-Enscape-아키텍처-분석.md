# Enscape 아키텍처 분석 — 시장 1위는 무엇을 택했나

> 조사일: 2026-09-07
> 목적: IRIS의 미결정 #1(타깃 GPU 범위)과 #3(구축 경로) 판단 근거 확보
> 출처는 문서 끝에 정리. **1차 출처(Chaos 공식 문서, AMD GPUOpen 기술 문서) 우선.**

---

## 요약 — 자료집의 권장 경로와 시장 1위의 실제 구현이 다릅니다

[자료집](01-실시간렌더러-오픈소스-자료집.md) 1장의 권장은 **경로 B(NVIDIA Donut + RTXDI + RTXPT + NRD + Streamline)**입니다.
이는 **RTX 전용** 아키텍처입니다.

그런데 Enscape의 실제 구현은 **자체 컴퓨트 BVH + 스크린스페이스 하이브리드**이고,
하드웨어 레이트레이싱은 **선택적 고품질 모드에만** 씁니다. 그 결과 Intel·AMD **내장 그래픽까지**
지원합니다.

자료집 스스로 "Enscape이 시장을 가져간 이유가 정확히 보급형에서도 돈다는 지점"이라고
적어 두었는데, 권장 스택은 그 반대 방향을 가리킵니다. **이 모순을 미결정 #1에서 정면으로
다뤄야 합니다.**

---

## 1. 지원 범위

### 1.1 호스트 앱 — 5개

| 호스트 | Windows | macOS |
|---|---|---|
| **Revit** | 2023~2027 | ❌ (Revit 자체가 Windows 전용) |
| **SketchUp** | 2024~2026 | ✅ 2024~2026 |
| **Rhino** | 7.0 / 8.3+ | ✅ |
| **Archicad** | 27~29 | ✅ |
| **Vectorworks** | 2024~2026 | ✅ |

**지원하지 않는 것이 더 시사적입니다.**

- **3ds Max·Blender·AutoCAD·ZWCAD에는 라이브 링크가 없습니다**
- 3ds Max·Cinema 4D는 `.vrscene` **단방향 내보내기**만 지원 — 같은 Chaos 제품군(V-Ray)인데도 그렇습니다
- macOS는 **Apple Silicon 전용**, Intel Mac 미지원

→ 라이브 링크는 호스트 하나당 별도 투자이며, 시장 1위조차 5개로 제한한다는 뜻입니다.
IRIS가 SketchUp 하나로 시작하는 것은 과소 투자가 아니라 정상 범위입니다.

### 1.2 기능

| 영역 | 내용 |
|---|---|
| 출력 | 동영상, 360° 파노라마, 배치 렌더, **독립 실행 .exe**, 웹 버전, 알파 채널 스크린샷, QR 코드 |
| VR | Meta Quest 3 / HTC Vive Pro 2. **VR 모델을 .exe로 내보내 오프라인 사용** |
| 시각화 모드 | 사실적 / 화이트 / 조도(lux) / 폴리스티롤 / 아웃라인 / 연필·수채 |
| 에셋 | 기본 머티리얼 425종+, Quixel Megascans, 커스텀 업로드, 변형(variant) |
| 협업 | Chaos Cloud 주석·마크업, BIM 정보 조회, 평면도 미니맵 |
| VRAM | 최소 4GB, 권장 8GB+, **VR은 12GB** |

---

## 2. 렌더링 아키텍처 — 핵심

Enscape는 **두 갈래**를 운영합니다.

### 2.1 실시간 모드 — 하드웨어 RT를 쓰지 않습니다

AMD GPUOpen에 공개된 기술 문서 기준:

| 요소 | 구현 |
|---|---|
| 기본 기법 | **Deferred path tracing** — 1차 광선을 쏘지 않고 **G-Buffer에서 출발** |
| 확산광 GI | **먼저 스크린스페이스**로 시도 → 이전 프레임 irradiance 버퍼에 적중하면 다중 바운스 반사를 사실상 공짜로 획득 |
| 실패 광선 | **자체 BVH**로 추적 (하드웨어 RT 코어 아님) |
| 광선 정렬 | **12개 월드스페이스 방향 묶음**으로 버킷 분리 → 캐시 일관성 확보 |
| BVH 관리 | 전체를 짓지 않고 **"조명 관련도 × BVH 비용"으로 가중해 스트리밍** |
| 지오메트리 전처리 | 고폴리곤·식생을 단순화 또는 절차적 표현으로 치환 |
| 필터링 | 시간 누적 버퍼 + neighborhood clamping + BRDF 인지 업샘플링 |
| 성능 조절 | BVH 복잡도·샘플 수·march 길이·해상도를 조절해 프레임레이트 유지 |
| 제약 | **다중 바운스 확산광은 Ultra 프로파일 전용** |

특성:
- 스크린스페이스 순회는 **콘텐츠 무관**(content agnostic) — 성능이 씬 복잡도에 둔감
- BVH 순회 성능은 폴리곤 수에 비례

### 2.2 패스트레이싱 모드 — 여기서만 RTX 필수

오프라인급 품질(정확한 GI·반사)을 내는 **별도 모드**이며, 이 모드에만 하드웨어
레이트레이싱이 필요합니다.

---

## 3. IRIS에 주는 시사점

### 3.1 미결정 #1 — 시장 1위의 답은 "둘 다, 주력은 폴백"

Enscape는 넓은 하드웨어를 자체 BVH로 커버하고 RTX는 옵션으로 얹었습니다.
IRIS가 선택할 수 있는 입장은 세 가지입니다.

| | 접근 | 장점 | 대가 |
|---|---|---|---|
| **가** | Enscape형 하이브리드 (자체 BVH + 스크린스페이스) | 시장 커버리지 최대, 보급형에서 정직한 성능 | **NVIDIA SDK 이점을 대부분 포기.** 직접 구현 부담이 매우 큼 |
| **나** | RTX 전용 (자료집 경로 B) | 자료집 추정 **6~12개월 내 데모**. SDK 조립으로 최고 품질 | 시장이 RTX 보유자로 제한. 내장 그래픽·구형 GPU 배제 |
| **다** | RTX 우선 + 폴백 후행 | 빠른 출시 후 확장 | GI 아키텍처 이중 유지. 자료집 경고 대상 |

**반론도 기록해 둡니다.** Enscape는 2015년경 출발이라 RTX가 존재하지 않던 시기에
자체 BVH를 만들 수밖에 없었습니다. 2026년 신규 진입자가 같은 제약을 물려받을 이유는
없습니다. "Enscape이 그렇게 했다"가 곧 "우리도 그래야 한다"는 아닙니다.

### 3.2 호스트 앱 확장은 서두를 일이 아님

시장 1위도 5개입니다. SketchUp 1개 확정은 정상적인 출발점입니다.

### 3.3 검증 항목 — 문서 간 불일치

Chaos **시스템 요구사항** 문서는 "전용 VRAM 필요, 내장 그래픽 미달"이라 하고,
Chaos **기능** 페이지는 "Intel·AMD 내장 그래픽 지원"이라고 합니다. **공식 문서끼리
어긋납니다.**

실시간 모드는 iGPU 가능 / 고품질·VR은 전용 GPU 필요로 갈린 것으로 보이나 확정하려면
실측이 필요합니다. **AI-00-002에 Enscape 2.5가 설치되어 있어 GTX 1060에서 관찰
가능합니다** — 구형 GPU 폴백 검증기로서의 용도가 여기서 생깁니다.

### 3.4 신뢰하지 않은 정보

"Neural Ray Tracing(NRT)", "Advanced Material Intelligence(AMI)" 등 2026 신기능
주장은 **교육업체 블로그 출처**이며 Chaos 공식 문서에서 확인되지 않았습니다.
마케팅 표현일 수 있어 위 분석에 반영하지 않았습니다.

---

## 출처

| 구분 | 출처 |
|---|---|
| 1차 (공식) | [System Requirements — Enscape (Chaos Docs)](https://docs-chaos.atlassian.net/wiki/spaces/enscape/pages/842039327/System+Requirements) |
| 1차 (공식) | [Features — Chaos Enscape](https://www.chaos.com/enscape/features) |
| 1차 (기술) | [Deferred Path Tracing By Enscape — AMD GPUOpen](https://gpuopen.com/learn/deferred-path-tracing-enscape/) |
| 2차 | [Enscape System Requirements 2026 — ArchPulse](https://www.archpulse.co/blog/enscape-system-requirements) |
