# SketchUp 프로브 — Phase 0-2 과제 4

SketchUp Ruby API로 지오메트리를 덤프해 **라이브 링크 실현성**을 판정합니다.
Phase 0의 산출물은 코드가 아니라 의사결정이므로, 실행 결과를 아래 "측정 결과"에 기록하십시오.

## 실행

SketchUp 2026에서 모델을 연 뒤 **창 > Ruby 콘솔**을 열고:

```ruby
load 'E:/IRIS/tools/sketchup/iris_probe.rb'
IRIS::Probe.run
```

| 호출 | 용도 |
|---|---|
| `IRIS::Probe.run` | 측정 + JSON 덤프 (`out/sketchup/<모델명>.iris.json`) |
| `IRIS::Probe.run(dump: false)` | 측정만. 대형 모델에서 시간 측정할 때 |
| `IRIS::Probe.run(pretty: true)` | 사람이 읽을 수 있게 들여쓴 JSON |
| `IRIS::Probe.watch` | 변경 감지 옵저버 부착 |
| `IRIS::Probe.flush` | 부착 이후 쌓인 델타 출력 후 비움 |
| `IRIS::Probe.unwatch` | 옵저버 해제 |

스크립트를 수정한 뒤에는 `load`를 다시 호출하면 그대로 갱신됩니다.

### 증분 동기화 테스트 절차

```ruby
IRIS::Probe.watch
# → SketchUp에서 박스 하나 그리기 / 옮기기 / 지우기
IRIS::Probe.flush
```

`watch`는 **최상위 `model.entities`에만** 옵저버를 붙입니다. 그룹·컴포넌트 내부 편집까지
잡으려면 각 `Entities`에 개별 부착이 필요하며, 이 범위 문제 자체가 라이브 링크 설계의
난점 중 하나이므로 결과를 기록해 두십시오.

## 출력 JSON 구조

렌더러가 바로 쓸 수 있는 2단 씬 그래프입니다. **정의(메시) / 인스턴스(변환)** 분리가 핵심이며
이것이 그대로 BLAS / TLAS 구조에 대응합니다.

```
definitions : { def_<id>: { meshes[], children[], persistent_id, instance_count } }
root        : { meshes[], children[] }
materials   : [ { id, name, color, alpha, type, texture } ]
```

- `meshes[]`는 **머티리얼별로 분리**되어 있습니다 = 드로우콜 / 지오메트리 분리 단위
- `positions`는 **미터**. SketchUp 내부 단위(인치)에서 변환됨
- 좌표계는 SketchUp 원본 유지 — **Z-up, 우수 좌표계**. Y-up 변환은 렌더러 임포터 책임
- `transform`은 16개 float, **열 우선(column-major)**, 이동 성분은 인덱스 12·13·14

## 확인할 것

| # | 항목 | 판정 기준 |
|---|---|---|
| 1 | 정점·법선·UV 추출 | 셋 다 `O`여야 렌더러 입력으로 충분 |
| 2 | `persistent_id` | `O`가 아니면 증분 동기화 불가 → 라이브 링크 설계 재검토 |
| 3 | 인스턴스/정의 재사용률 | 1.0에 가까우면 인스턴싱 이득 없음 → 실제 BIM 모델로 재측정 |
| 4 | 추출 처리량 | 1000만 삼각형 환산 시간이 최초 로딩 비용의 하한 |
| 5 | 삭제 델타 | `onElementRemoved`가 entityID만 준다는 점 확인 |

## 알려진 제약

- **삭제 콜백은 `entityID`만 전달합니다.** 엔티티가 이미 무효라 `persistent_id`를 조회할 수 없습니다.
  → 렌더러 측에서 `entityID → persistent_id` 매핑 테이블을 자체 유지해야 합니다. 라이브 링크
  아키텍처에 직접 영향을 주는 제약입니다.
- 이 프로브는 **Ruby API만** 사용합니다. 자료집 10.2가 지적한 대로 실제 제품에서는
  지오메트리 추출을 C API(SketchUp SDK)로 옮겨야 할 가능성이 높으며, 그 판단 근거가
  여기서 나오는 처리량 수치입니다.
- SketchUp 2026의 임베디드 Ruby는 **3.2**입니다 (`x64-ucrt-ruby320.dll`).

## 측정 결과

> 실행 후 여기에 기록하십시오. 미결정 #2(1순위 호스트 앱) 판단 근거가 됩니다.

| 모델 | 삼각형 | 정의/인스턴스 | 추출 시간 | 법선·UV | persistent_id | 비고 |
|---|---|---|---|---|---|---|
| _(미측정)_ | | | | | | |
