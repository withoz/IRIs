# IRIS — 최상위 빌드 파일
#
# 두 가지 방식으로 쓰입니다.
#
#   1. 단독      cmake -S E:/IRIS -B E:/IRIS/build
#                엔진 없이 src/ 와 tests/ 만 빌드합니다. 반복이 빨라
#                프로토콜 계층을 여기서 만들고 시험합니다.
#
#   2. 엔진에서  RTXPT 포크가 add_subdirectory(${IRIS_SRC_DIR}) 로 끌어갑니다.
#                그때는 IRIS_BUILD_TESTS 를 끄고 라이브러리만 만듭니다.
#
# 주의: CMAKE_CXX_FLAGS 를 통째로 덮어쓰지 마십시오. MSVC 기본값(/EHsc 등)이
# 사라집니다. 한글 로케일 대응(/utf-8)은 target_compile_options 로 겁니다.
# 근거: docs/04-RTXPT-실측.md 1.2절

cmake_minimum_required(VERSION 3.20)

project(IRIS LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

option(IRIS_BUILD_TESTS "IRIS 시험 실행 파일을 빌드한다" ON)

# 엔진 체크아웃 위치. jsoncpp 를 여기서 빌려 씁니다 — 엔진과 같은 버전을 쓰기
# 위해서이고, 새 의존성을 만들지 않기 위해서입니다.
if(NOT DEFINED IRIS_ENGINE_DIR)
    if(DEFINED ENV{IRIS_ENGINE_DIR})
        set(IRIS_ENGINE_DIR "$ENV{IRIS_ENGINE_DIR}")
    else()
        set(IRIS_ENGINE_DIR "E:/iris-ext/RTXPT")
    endif()
endif()
set(IRIS_ENGINE_DIR "${IRIS_ENGINE_DIR}" CACHE PATH "RTXPT 포크 경로")

add_subdirectory(src)

if(IRIS_BUILD_TESTS)
    enable_testing()
    add_subdirectory(tests)
endif()
