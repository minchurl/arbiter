# XIndex/YCSB-A Full-Trace Hot-Set Broad Sweep 정리

- 작성일: 2026-09-18
- 대상 실행: 2026-08-22 broad sweep v2
- 상태: screening 완료, confirmation/final 미실행

이 문서는 XIndex/YCSB-A benchmark가 실제로 어떻게 실행되고 처리량이
어떻게 측정되는지, Arbiter local/CXL 비교가 무엇을 뜻하는지, 마지막
full-trace broad parameter sweep을 어떤 설정으로 계획했으며 실제로 어디까지
진행됐는지를 한곳에 정리한 공유용 문서다.

## 1. 요약

- 마지막 실험은 특정 allocation site ID를 수동으로 지정한 실험이 아니다.
  Compiler의 정적 HITM-risk score와 hot-set 선택 파라미터 100개 조합을
  생성하여 자동 선택 결과를 비교했다.
- `ARBITER_HITM_SEED_SITE_IDS`는 모든 설정에서 비어 있었다. 실제 hardware
  HITM을 profiling하여 고른 것도 아니다. 현재 HITM score는 escape, sync,
  worker reachability, allocation size 등을 이용한 정적 proxy다.
- 100M load record와 400M YCSB-A transaction이 들어 있는 full-size trace를
  사용했다. 다만 각 screening row의 transaction 측정은 15초 duration
  mode였고, 400M transaction을 정확히 한 번 수행하고 종료하는 방식은
  아니었다.
- 각 row는 새로운 프로세스였다. 약 1분 동안 trace를 읽고 100M-key
  XIndex를 새로 구축한 뒤, 15초 동안 메모리 내 `get`/`put` 처리량을
  측정했다. Local/CXL pair는 이 전체 과정을 각각 다시 수행했다.
- 100개 설정 중 18개의 statically unique candidate가 screening에 들어갔다.
  두 native anchor와 18개의 local/CXL pair, 총 38개 프로세스가 측정값을
  남겼다.
- OOM, swap, arena fallback, timeout, placement-query error는 없었다. 최대
  RSS는 약 33.26 GiB로 64G hard limit 안이었다.
- Runtime arena activity가 있었던 14개 candidate는 CXL/local 기준
  +40.24%에서 +103.53%의 15초 신호를 보였다. 그러나 candidate당 독립
  pair가 한 번뿐이고 confirmation이 실행되지 않았으므로 최종 성능
  향상으로 주장할 수 없다.
- Screening 후 ranking CSV의 separator가 빠지는 controller bug가 발생하여
  confirmation, final, native-end는 실행되지 않았다. 현재 driver에는 해당
  버그와 promotion ID 검증이 수정되어 있지만 수정 후 재실행하지 않았다.
- 가장 신뢰할 수 있는 기존 장기 결과는 별도의 20M/80M auto-k1 실험에서
  얻은 7 paired round 평균 CXL/local +12.58%다. 마지막 full-trace의
  +40~103%는 장기 결과가 아니라 후속 검증 후보를 고르는 근거다.

## 2. 지금까지의 연구 흐름

### 2.1 Direct per-object allocation

초기 구현은 선택된 객체마다 `numa_alloc_onnode`를 호출하고 side table에
소유권을 기록했다. 작은 96B 객체도 사실상 page 단위 비용을 만들었고,
allocation/free 및 side-table overhead가 매우 컸다. 이 구현에서는 CXL
배치 효과보다 runtime allocator 비용이 결과를 지배했다.

### 2.2 Site별 slab/arena

이를 fixed-size allocation site별 2 MiB NUMA-bound slab/arena로 변경했다.
작은 객체를 slab에 조밀하게 배치하고, 예약된 가상 주소 범위로 arena
pointer를 판별하여 per-object side table을 제거했다. 이 변경으로 96B
객체의 page amplification과 per-object NUMA allocation 비용을 크게 줄였다.

### 2.3 수동 site 99와 자동 선택

- Site 99를 수동으로 선택한 20M/80M 장기 실험에서는 CXL/local 평균이
  +0.26%로 사실상 중립이었다.
- Partial-scale automatic-k1 장기 실험에서는 CXL/local 평균 +12.58%, 7/7
  CXL 승리, 1시간 soak 안정성을 확인했다.
- 그러나 full-scale에서는 partial-scale의 site 97/99가 runtime에 실제로
  allocation되지 않았다. Full-scale active site는 주로 68, 69, 71이었다.

이 차이 때문에 마지막 실험은 site 99를 고정하지 않고 parameter space를
넓게 탐색하고, static top-k가 아니라 실제 runtime site fingerprint와
resident bytes를 확인하는 방향으로 설계했다.

## 3. XIndex/YCSB-A benchmark 구조

### 3.1 두 입력 trace

이번 full-scale 입력은 다음과 같다.

| 입력 | 크기 | 역할 |
|---|---:|---|
| Load trace | 100,000,000 records, 약 5.4 GB | 초기 XIndex에 넣을 key 집합 |
| Transaction trace | 400,000,000 operations, 약 21.8 GB | 구축 후 수행할 YCSB-A workload |

실제 transaction 구성은 다음과 같다.

| Operation | 개수 |
|---|---:|
| READ | 199,993,860 |
| UPDATE | 200,006,140 |
| INSERT | 0 |
| REMOVE | 0 |

즉 거의 정확한 50% read / 50% update workload다. READ는
`XIndex::get()`, UPDATE는 `XIndex::put()`으로 실행된다.

### 3.2 한 row의 실행 순서

한 번의 native/local/CXL row는 다음 순서로 실행된다.

```text
새 프로세스 시작
  -> 100M load trace 전체 파싱
  -> 400M transaction trace 전체 파싱 및 operate_queue 생성
  -> 100M key 정렬
  -> XIndex 생성 및 training
  -> foreground 31개 + background 1개 worker 준비
  -> benchmark timer 시작
  -> 15초 동안 get/put transaction 실행
  -> foreground operation counter 합산
  -> arena residency, RSS, wall time 기록
  -> 프로세스 종료
```

Compiler build는 매 row마다 하지 않는다. 100개 raw config의 build/report와
안전성 검사를 screening 전에 한 번씩 수행하고, 이를 통과해 선택된 18개
binary를 각 runtime row에서 재사용한다. 반면 trace parsing과 XIndex 구축은
매 row마다 새로 수행한다.

### 3.3 Full trace와 15초 duration의 의미

`full trace`는 축소 trace가 아니라 100M/400M 원본 파일을 사용하고
full-size XIndex를 구축했다는 뜻이다. 그러나 broad sweep은 다음 설정을
사용했다.

```text
XINDEX_DURATION_SECONDS=15
```

Duration mode에서 31개 foreground worker는 400M transaction queue를 서로
나눠 갖는다. 각 worker가 자신의 구간을 끝냈는데 15초가 남아 있으면 같은
구간을 처음부터 다시 수행한다. 따라서 빠른 실행은 400M operation을 한 번
이상 반복한다.

예를 들어 `raw-021`은 다음과 같았다.

```text
Local: 422,217,134 ops / 15.0064 s = 28.14M op/s
       전체 400M trace의 약 1.06회

CXL:   859,215,189 ops / 15.0043 s = 57.26M op/s
       전체 400M trace의 약 2.15회
```

따라서 정확한 표현은 다음과 같다.

> 100M/400M full-scale 입력을 전부 메모리에 적재하고 XIndex를 구축한 뒤,
> transaction queue를 15초 동안 반복 실행하여 steady-state op/s를
> 측정했다.

### 3.4 처리량 측정 방법

보고된 성능은 disk I/O throughput이 아니다. 각 foreground worker는 trace
operation 하나에 대응하는 `get` 또는 `put` 호출을 수행한 뒤 thread-local
counter를 1 증가시킨다. 최종 처리량은 다음과 같다.

```text
Throughput(op/s)
  = 모든 foreground worker가 수행한 operation 수의 합
    / CLOCK_MONOTONIC으로 측정한 transaction 구간 시간
```

Timer는 trace I/O, sorting, XIndex training 및 worker 준비가 끝난 뒤
시작한다. 따라서 다음 비용은 `op/s`에 포함되지 않는다.

- trace 파일 읽기 및 파싱
- 초기 key 정렬
- XIndex 초기 training/build
- 측정 전에 발생한 arena allocation
- candidate compiler build

반면 `/usr/bin/time -v`의 `wall_time`과 `max_rss_kb`는 프로세스 전체를
대상으로 하므로 초기 구축도 포함한다.

| 기록값 | 의미 |
|---|---|
| `time_sec` | transaction timer 구간 |
| `throughput` | foreground operations / `time_sec` |
| `wall_time` | trace parsing부터 프로세스 종료까지 전체 시간 |
| `max_rss_kb` | 전체 프로세스 생애 중 peak RSS |

마지막 screening에서 15초 candidate row의 전체 wall time은 약 1분
13초~1분 30초였다. `raw-021`의 경우 local은 1분 20.77초, CXL은 1분
30.22초였다. 즉 CXL의 transaction throughput은 높았지만 초기 구축을
포함한 15초짜리 작업 전체가 두 배 빨라진 것은 아니다.

### 3.5 5초 throughput sampler

Screening은 5초마다 중간 counter도 기록했다. Worker는 operation마다
atomic increment를 하지 않고, 일반 thread-local counter를 사용하며 256개
operation마다 stop/sample epoch를 확인한다. `raw-021`의 구간 처리량은
다음처럼 15초 안에서는 안정적이었다.

| 구간 | Local | CXL |
|---|---:|---:|
| 0~5초 | 28.20M op/s | 57.36M op/s |
| 5~10초 | 28.21M op/s | 56.99M op/s |
| 10~15초 | 28.00M op/s | 57.44M op/s |

이 세 sample은 한 프로세스 안에서 얻었으므로 독립적인 3회 반복은 아니다.

## 4. Native, pick/local, pick/CXL 비교

| 모드 | 의미 |
|---|---|
| `native` | Arbiter rewrite/runtime를 적용하지 않은 XIndex |
| `pick/local` | Compiler가 선택한 site를 arena ABI로 rewrite하고 arena를 node 0에 배치 |
| `pick/CXL` | 동일한 rewritten binary의 arena만 CXL node 2에 배치 |

Candidate 하나의 local과 CXL은 같은 selection, config, binary를 사용하고
arena node만 바뀐다. 선택되지 않은 일반 allocation은 node 0에 남는다.
객체를 실행 중 node 0에서 node 2로 migration하는 방식이 아니라, 선택된
allocation이 처음 생성될 때부터 local 또는 CXL arena에서 생성된다.

주요 비교식은 다음과 같다.

```text
CXL/local delta (%)
  = (pick/CXL throughput / pick/local throughput - 1) * 100
```

- `pick/local` 대 `native`: compiler rewrite와 arena 자체의 overhead
- `pick/CXL` 대 `pick/local`: 동일한 Arbiter binary에서 placement만 바꾼 효과
- `pick/CXL` 대 `native`: 전체 end-to-end 효과

Broad sweep에서는 native를 candidate마다 paired 실행하지 않고 시작/중간/끝
machine-drift anchor로만 계획했다. 따라서 candidate ranking에는
`pick/CXL` 대 `pick/local`을 사용했다.

## 5. 고정된 시스템 및 안전 설정

| 항목 | 설정 |
|---|---:|
| Workload | XIndex + YCSB A |
| Load / transaction | 100M / 400M |
| Foreground / background | 31 / 1 |
| CPU node | 0 |
| 일반/local memory node | 0 |
| CXL node | 2 |
| Arena slab | 2 MiB |
| Arena reserve | 24 GiB virtual, `MAP_NORESERVE` |
| Arena slot alignment | 64 B |
| Arena mode | strict, report enabled, fallback 금지 |
| `MemoryMax` | 64G |
| `MemorySwapMax` | 0 |
| Controller 최대 시간 | 8시간 |
| Screen cooldown | pair row 사이 2초 |

실행은 user systemd scope 안에서 수행됐고, benchmark process는 다음과 같이
node 0 CPU와 기본 메모리에 묶였다.

```text
numactl --cpunodebind=0 --membind=0
```

Arena runtime이 선택된 객체에 대해서만 node 0 또는 node 2를 명시적으로
지정한다. 실행 종료 시 arena page의 실제 NUMA residency를 query하여 local
row는 majority node 0, CXL row는 majority node 2인지 검증했다.

### Cache 및 외부 프로세스 조건

- 각 row는 fresh process여서 XIndex, heap, arena, counter는 초기화됐다.
- Linux filesystem page cache는 `drop_caches`로 비우지 않았다.
- CPU cache를 명시적으로 flush하지 않았다.
- Trace page cache는 의도적으로 warm/shared 상태로 유지했다.
- Local-first/CXL-first 순서는 pair마다 교대했다.
- Benchmark는 node 0에 bind했지만 exclusive cpuset은 만들지 않았다.
- VS Code, Codex, OS task를 node 1로 강제 이동하지 않았다.

따라서 strict cold-cache 비교가 아니며, 외부 task가 node 0에서 실행했다면
CPU contention이 결과에 영향을 줄 수 있다. 다음 실행에서는 trace를 한 번
prewarm한 뒤 cache를 유지하고, benchmark node 0과 OS/editor node 1을
cpuset으로 격리하는 것이 권장된다.

## 6. Compiler의 자동 hot-set 선택

### 6.1 Stage 1: HITM-risk seed

실제 HITM counter를 보고 선택한 것이 아니다. Compiler가 allocation
site마다 다음 정적 신호를 조사하여 HITM-risk score를 만든다.

- allocation-derived pointer의 return/store/call escape
- atomic, volatile store, lock/cmpxchg inline assembly 등의 sync 신호
- pthread worker entry 또는 worker-reachable code
- allocation size

Automatic seed는 escape/sync gate와 최소 score를 통과한 site 중 score
내림차순, site ID 오름차순으로 정렬하여 `SEED_LIMIT`만큼 선택한다.

### 6.2 Stage 2: 연결 member

`HOTSET_EXPANSION=use`이면 seed-relative pointer path에 붙은 다른 allocation을
추적한다. Member affinity는 다음과 같다.

| Affinity | 의미 |
|---:|---|
| 1 | seed-relative path에 attach됨 |
| 2 | pointer load/null-check 등 pointer evidence |
| 3 | pointee read |
| 5 | pointee write/atomic/mutating call |

이는 접근 빈도가 아니다. Read를 한 번 보든 열 번 보든 affinity는 3이다.
따라서 현재 구현은 “실제로 많이 접근되는 object”를 runtime profile로 고르는
방식이 아니며, profile-guided frequency selection은 다음 연구 방향이다.

## 7. Broad sweep parameter 설정

### 7.1 Candidate 생성

- Deterministic search seed: `20260820`
- Raw candidate: 100개
- 처음 14개: auto-k1/k2/k3/k6 및 설계된 reference point
- 나머지 86개: deterministic pseudo-random parameter 조합
- Static selected-site fingerprint가 같으면 중복 제거
- Screening 상한: 50 static-unique candidate

`HOTSET_SEARCH_SEED=20260820`은 parameter 조합을 재현하기 위한 난수 seed다.
Allocation site를 지정하는 `HITM_SEED_SITE_IDS`와는 관계없다.

### 7.2 모든 candidate의 공통값

```text
ARBITER_HITM_SEED_SITE_IDS=
ARBITER_HITM_INCLUDE_DYNAMIC_SIZE=0
ARBITER_HOTSET_INCLUDE_MMAP=0
ARBITER_HOTSET_DYNAMIC_SIZE_ESTIMATE=4096
```

Dynamic-size site를 제외한 이유는 현재 slab/arena가 site별 고정 slot 크기를
사용하기 때문이다. V1에서는 site 72처럼 실행 중 allocation size가 변하는
site가 선택되어 strict arena가 null을 반환하고 XIndex가 SIGSEGV로 종료됐다.
V2는 compiler report에 nonconstant-size selected site가 있으면 실행 전에
해당 candidate를 제외했다.

### 7.3 변경한 parameter 범위

| 환경변수 | 의미 | 생성한 값 |
|---|---|---|
| `ARBITER_HITM_MIN_SCORE` | HITM minimum score | 4, 5, 6, 7, 8, 10, 12, 13, 14 |
| `ARBITER_HITM_SEED_LIMIT` | Seed limit | 1, 2, 3, 4, 6, 8, 12, 16, 24 |
| `ARBITER_HITM_REQUIRE_ESCAPE` / `ARBITER_HITM_REQUIRE_SYNC` | Escape/sync gates | 1/1, 1/0, 0/1, 0/0 |
| `ARBITER_HITM_LARGE_ALLOCATION_THRESHOLD` | Large-allocation threshold | 64, 96, 128, 512, 4096, 16384 B |
| `ARBITER_HITM_WEIGHT_*` | Weight bundle | default, escape-heavy, sync-heavy, worker-heavy, size-heavy, flat, hybrid |
| `ARBITER_HOTSET_EXPANSION` | Member expansion | `none`, `use` |
| `ARBITER_HOTSET_MAX_SITES` | Total site cap | 1, 2, 3, 4, 6, 8, 12, 16, 24, 32 |
| `ARBITER_HOTSET_MAX_ESTIMATED_BYTES` | Static byte budget | unlimited(0), 1 KiB, 16 KiB, 32 KiB, 64 KiB |
| `ARBITER_HOTSET_MAX_MEMBERS_PER_SEED` | Members per seed | 1, 2, 4, 6, 8 |
| `ARBITER_HOTSET_MEMBER_MIN_AFFINITY` | Member affinity threshold | 1, 3, 5 |
| `ARBITER_HOTSET_MEMBER_MAX_CALL_DEPTH` | Direct-call depth | 0, 1, 2, 3 |
| `ARBITER_HOTSET_MEMBER_MAX_LOAD_DEPTH` | Pointer-load depth | 0, 1, 2, 3, 4 |

Static byte budget은 runtime CXL RSS 제한이 아니다. 선택된 static site의
allocation size를 한 번씩 합산한 compile-time budget이다. 같은 site가
runtime에 수천만 번 allocation되면 1 KiB static budget 설정도 수십 GiB
arena residency를 만들 수 있다.

## 8. 계획했던 adaptive 실험

| 단계 | Candidate | 추가 local/CXL pair | Row 측정 시간 | Sample 주기 |
|---|---:|---:|---:|---:|
| Screen | 최대 50 | 1 | 15초 | 5초 |
| Confirmation | 최대 16 | 2, 총 3 pair | 60초 | 10초 |
| Final | 최대 5 | 4, 총 7 pair | 180초 | 30초 |

Screen promotion 조건은 다음과 같았다.

- local/CXL 두 row 모두 정상
- swap, arena fallback, placement query error가 0
- local majority node 0, CXL majority node 2
- 두 row의 runtime allocation-site fingerprint가 동일하고 비어 있지 않음
- CXL/local delta가 -15% 이상
- 같은 runtime fingerprint당 최대 두 candidate
- 전체 최대 16 candidate

Confirmation에서는 3개 pair 평균이 -10% 미만인 candidate를 제거하고,
runtime fingerprint당 하나, 최대 5개를 final로 보낼 계획이었다. Final은
총 7개의 fresh-process pair 평균, 표준편차, CXL 승리 횟수를 보고하도록
설계했다.

## 9. 실제 진행 결과

### 9.1 Build/filter 단계

| 상태 | 개수 | 해석 |
|---|---:|---|
| Screening 선택 | 18 | 서로 다른 static site fingerprint |
| Nonconstant-size로 안전 제외 | 56 | build/report 후 arena incompatibility로 미실행 |
| Duplicate static fingerprint | 21 | 먼저 나온 대표 candidate만 유지 |
| 선택 site 없음 | 4 | rewrite할 site가 없음 |
| Config/build 실패 | 1 | 선택 seed가 16 KiB static budget을 초과 |

유일한 build 실패는 일반 compiler crash가 아니라 다음 config invariant를
fail-closed로 검출한 것이다.

```text
selected HITM seeds exceed hotset max-estimated-bytes 16384
```

### 9.2 실행 단계

실제 순서는 다음과 같았다.

```text
native-start 60초
  -> 18 candidate x (local 15초 + CXL 15초)
  -> native-middle 60초
  -> phase-1 ranking 생성
  -> controller CSV bug로 중단
```

총 38개 fresh process가 측정값을 남겼다.

- `ok`: 30 rows
  - native 2 rows
  - runtime arena activity가 있었던 14 candidate의 local/CXL 28 rows
- `arena-report-missing`: 8 rows
  - static 선택은 있었지만 runtime allocation이 없었던 4 candidate pair

Screening 후 ranking writer가 CSV separator를 빠뜨려 다음과 같이 출력했다.

```text
정상 기대: 1,raw-021,103.529,68+69+71+74
실제 출력: 1raw-021103.52968+69+71+74
```

그 결과 promotion candidate ID가 비어 `C_CONFIG: bad array subscript`로
중단됐다. Benchmark, OOM 또는 placement 실패가 아니라 controller parsing
실패다. Confirmation, final, native-end는 실행되지 않았다.

## 10. Screening 결과

### 10.1 안전성과 native drift

- OOM: 0
- Swap: 0
- Timeout: 0
- Arena fallback: 0
- Placement-query error: 0
- 최대 RSS: 34,880,124 KiB, 약 33.26 GiB
- 최대 CXL-resident arena: 20,275,609,600 B, 약 18.88 GiB
- Native-start: 26.7045M op/s
- Native-middle: 27.2819M op/s
- Native anchor drift: +2.16%

64G/zero-swap envelope에서 fixed-size full-scale placement가 안전하게 실행된
점은 신뢰할 수 있다.

### 10.2 Runtime footprint별 결과

| Runtime sites | Candidate | CXL/local | CXL-resident arena / peak RSS |
|---|---|---:|---:|
| `68` | `raw-003`, `raw-004`, `raw-036` | +40.24%~+58.71% | 3.15 GiB / 9.87% |
| `68+69` | `raw-009`, `raw-047` | +44.84%~+45.32% | 4.72 GiB / 14.19% |
| `71` | `raw-014`, `raw-082` | +58.48%~+78.17% | 14.16 GiB / 48.12% |
| `68+71+74` | `raw-039`, `raw-046` | +97.22%~+97.51% | 17.31 GiB / 57.32% |
| `68+69+71` | `raw-013` | +101.92% | 18.88 GiB / 59.81% |
| `68+69+71+74` | `raw-021` | +103.53% | 18.88 GiB / 59.81% |

### 10.3 Screening 상위 5개

| 순위 | Candidate | Local | CXL | Delta | Runtime sites | CXL/RSS |
|---:|---|---:|---:|---:|---|---:|
| 1 | `raw-021` | 28.14M | 57.26M | +103.53% | `68+69+71+74` | 59.81% |
| 2 | `raw-013` | 28.47M | 57.49M | +101.92% | `68+69+71` | 59.81% |
| 3 | `raw-043` | 29.03M | 57.81M | +99.14% | `21+37+68+69+71+74` | 59.81% |
| 4 | `raw-046` | 28.06M | 55.42M | +97.51% | `68+71+74` | 57.32% |
| 5 | `raw-039` | 28.52M | 56.24M | +97.22% | `68+71+74` | 57.33% |

상위 3개는 서로 완전히 다른 현상이 아니다. 모두 실제 resident bytes가
18.88 GiB로 같고, 68/69/71이 대부분을 차지한다. Site 74와 21/37의 추가
resident volume은 매우 작다. 따라서 상위 3개를 독립적인 세 번의 성공으로
해석하면 안 된다.

## 11. 상위 candidate의 실제 parameter

상위 5개는 모두 `HOTSET_EXPANSION=none`이었다. 즉 Stage 2 member 확장이
아니라 Stage 1에서 여러 automatic seed를 선택한 결과다. Affinity 및
call/load depth 값은 config에 존재하지만 expansion이 꺼져 있어 실제
selection에는 영향을 주지 않는다.

| Candidate | Weight | Min score | Seed limit | Escape/sync gate | Size threshold | Max sites | Static byte budget |
|---|---|---:|---:|---|---:|---:|---:|
| `raw-021` | default | 8 | 16 | 1 / 1 | 64 B | 16 | 16 KiB |
| `raw-013` | flat | 8 | 8 | 0 / 1 | 64 B | 8 | 1 KiB |
| `raw-043` | size-heavy | 4 | 12 | 1 / 0 | 64 B | 12 | 16 KiB |
| `raw-046` | size-heavy | 7 | 12 | 1 / 1 | 128 B | 12 | unlimited |
| `raw-039` | size-heavy | 10 | 8 | 1 / 0 | 64 B | 8 | 16 KiB |

### 11.1 Weight bundle

| Bundle | Escape return/store/call | Sync atomic/store/asm/file | Worker entry/reachable | Size |
|---|---|---|---|---:|
| default | 3 / 3 / 2 | 3 / 2 / 2 / 1 | 3 / 2 | 1 |
| flat | 2 / 2 / 2 | 2 / 2 / 2 / 2 | 2 / 2 | 2 |
| size-heavy | 2 / 2 / 1 | 2 / 1 / 1 / 1 | 2 / 1 | 6 |

### 11.2 Candidate별 선택 결과

| Candidate | Static selected sites | Runtime active sites |
|---|---|---|
| `raw-021` | `68+69+71+74+90+97+98+99+100` | `68+69+71+74` |
| `raw-013` | `68+69+71+90+97+98+99+100` | `68+69+71` |
| `raw-043` | `21+37+54+68+69+71+74+90+97+98+99+100` | `21+37+68+69+71+74` |
| `raw-046` | `68+71+74+90+97+98+99+100` | `68+71+74` |
| `raw-039` | `68+71+74+90+97+99` | `68+71+74` |

이 결과는 static top-k 이름보다 runtime fingerprint를 확인해야 함을 보여
준다. 예를 들어 static auto-k3와 k6는 다른 set이지만 full-scale runtime에는
둘 다 site 68만 allocation했다.

정확한 config 원본:

- [`raw-021.config`](artifacts/hotset-broad-sweep-v2-20260822-012131/configs/raw-021.config)
- [`raw-013.config`](artifacts/hotset-broad-sweep-v2-20260822-012131/configs/raw-013.config)
- [`raw-043.config`](artifacts/hotset-broad-sweep-v2-20260822-012131/configs/raw-043.config)
- [`raw-046.config`](artifacts/hotset-broad-sweep-v2-20260822-012131/configs/raw-046.config)
- [`raw-039.config`](artifacts/hotset-broad-sweep-v2-20260822-012131/configs/raw-039.config)

## 12. 이전 full-scale short run과의 비교

큰 CXL/local 신호가 V2에서 처음 한 번만 나온 것은 아니다.

| 실행 | 측정 | Runtime sites | Local | CXL | Delta |
|---|---:|---|---:|---:|---:|
| 2026-08-19 preflight | 5초 | `68` | 28.22M | 44.02M | 약 +56.0% |
| Broad v1 | 15초 | `68+69+71` | 28.16M | 58.06M | +106.15% |
| Broad v2 | 15초 | `68+69+71` | 28.47M | 57.49M | +101.92% |

특히 V1/V2의 `68+69+71` 절대 처리량이 매우 비슷한 것은 흥미로운 반복
신호다. 다만 V1 controller aggregate parser는 깨져 있었고 raw row에서
재구성했으며, 두 broad run 모두 candidate당 한 pair뿐이었다. 또한 5초
preflight의 site-68 local은 cold, CXL은 warm 실행이라 엄격히 paired된
결과가 아니다.

## 13. 신뢰도와 주장 가능한 범위

| 질문 | 현재 판단 |
|---|---|
| Full-size 100M/400M 입력을 실제 사용했는가? | 예 |
| 64G 제한에서 OOM 없이 실행 가능한가? | 테스트한 fixed-size 설정에서는 예 |
| Arena page가 의도한 NUMA node에 있었는가? | Residency query로 확인 |
| Site 68/69/71이 full-scale runtime active인가? | 예 |
| 이 site set들이 장기 실험 후보로 유망한가? | 예 |
| CXL이 장기적으로 +40~103% 빠른가? | 아직 결론 불가 |
| HITM 감소가 성능 원인인가? | Counter가 없어 확인 불가 |
| 프로그램 시작부터 종료까지 두 배 빨라졌는가? | 아님; 보고값은 transaction op/s |

성능 수치의 한계는 다음과 같다.

- Candidate당 15초 local/CXL pair 한 번
- Confirmation/final 미실행
- 같은 runtime site set을 가진 상위 candidate가 많아 독립 표본 수가 적음
- Native가 candidate마다 paired되지 않음
- Native-start와 native-middle 사이에도 2.16% drift 존재
- OS/editor/Codex의 node-1 격리 미적용
- Filesystem page cache reset 미적용
- HITM/op, C2C, p99 latency 미측정
- `get`/`put` return value를 throughput 성공률 검증에 사용하지 않음

따라서 현재 문서에서 사용할 수 있는 가장 안전한 표현은 다음과 같다.

> Full-scale XIndex/YCSB-A short screening에서 runtime site 68, 69, 71을
> CXL에 배치한 설정들이 반복적으로 큰 positive throughput signal을 보였다.
> Fixed-size arena placement와 64G safety envelope는 검증됐지만, 성능 크기와
> HITM 개선 메커니즘은 장기 paired run과 hardware counter로 확인해야 한다.

## 14. 다음 실험 후보와 방법

Static ranking 상위 5개를 모두 돌리기보다 runtime footprint당 대표 하나를
고르는 것이 좋다.

| 목적 | Candidate | Runtime sites | CXL/RSS | Screen delta |
|---|---|---|---:|---:|
| 작은 배치 | `raw-003` | `68` | 9.87% | +58.71% |
| 작은 배치 확장 | `raw-009` | `68+69` | 14.19% | +45.32% |
| 목표 30~55% 중심 | `raw-082` | `71` | 48.12% | +58.48% |
| 높은 배치 | `raw-046` | `68+71+74` | 57.32% | +97.51% |
| 공격적 winner | `raw-021` | `68+69+71+74` | 59.81% | +103.53% |

`raw-082`는 static/runtime site가 모두 71 하나라 해석이 가장 깔끔하고,
약 48% CXL/RSS로 목표했던 30~55% 범위에 들어온다. `raw-021`은 default
weight 기반이라 공격적 후보 중 설명이 쉽다.

권장 확인 순서:

1. 수정된 driver의 `--check` 실행
2. Trace prewarm 1회 후 page cache 유지
3. Benchmark는 exclusive node-0 cpuset, OS/editor는 node 1로 격리
4. Runtime footprint별 대표를 3 pair x 60초로 확인
5. 살아남은 후보를 최소 7 pair x 180초, 가능하면 10~15분 row로 확인
6. Native/local/CXL 순서를 block 단위로 균형화
7. Transaction throughput과 전체 startup wall time을 둘 다 보고
8. HITM/op, HITM/s, perf c2c, p99 latency를 함께 수집

## 15. 관련 자료

- [Broad sweep 영문 결과 원장](hotset-broad-sweep-results.md)
- [Broad sweep 계획과 실행 명령](hotset-broad-sweep-plan.md)
- [V2 raw artifact 설명](artifacts/hotset-broad-sweep-v2-20260822-012131/README.md)
- [V2 phase-1 summary](artifacts/hotset-broad-sweep-v2-20260822-012131/phase1-summary.csv)
- [V2 observations](artifacts/hotset-broad-sweep-v2-20260822-012131/observations.csv)
- [V2 throughput samples](artifacts/hotset-broad-sweep-v2-20260822-012131/throughput-samples.csv)
- [Hot-set compiler/runtime 설계](../hotset-migration.md)
- [현재 broad sweep driver](../../scripts/run-hotset-broad-sweep-overnight.sh)
