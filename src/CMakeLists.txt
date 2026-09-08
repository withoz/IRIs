# IRIS 고유 코드.
#
# 엔진(RTXPT 포크)에 의존하지 않는 계층부터 쌓습니다. iris_protocol 은
# Donut/nvrhi 를 전혀 모르므로 단독으로 빌드하고 시험할 수 있습니다.
# 엔진과 만나는 것은 나중에 추가할 iris_bridge 입니다.

# --- 경고 설정 ---------------------------------------------------------------
# 우리 코드는 엄격하게, 서드파티 헤더는 그대로 둡니다.
#
# /external:anglebrackets + /external:W0 이 그 경계입니다 — IRIS 헤더는 따옴표로,
# Donut·jsoncpp 는 꺾쇠로 포함하므로 자동으로 갈립니다. 이것 없이 /W4 /WX 를 걸면
# Donut 의 SceneGraph.h 에서 C4100(참조되지 않은 매개 변수)이 나서 빌드가 멈춥니다.
if(MSVC)
    set(IRIS_WARNING_FLAGS /W4 /WX /external:anglebrackets /external:W0)
else()
    set(IRIS_WARNING_FLAGS)
endif()

# --- jsoncpp -----------------------------------------------------------------
# 엔진 빌드 안에서는 Donut 이 이미 jsoncpp_static 을 만들어 둡니다. 단독 빌드일
# 때만 같은 소스(amalgam 2개 파일)를 우리가 컴파일합니다. 버전이 갈리지 않게
# 항상 엔진 체크아웃의 것을 씁니다.
if(TARGET jsoncpp_static)
    set(IRIS_JSON_TARGET jsoncpp_static)
else()
    set(_amalgam "${IRIS_ENGINE_DIR}/External/Donut/thirdparty/jsoncpp-amalgam")
    if(NOT EXISTS "${_amalgam}/jsoncpp.cpp")
        message(FATAL_ERROR
            "jsoncpp 를 찾을 수 없습니다: ${_amalgam}\n"
            "  엔진 체크아웃이 없거나 경로가 다릅니다.\n"
            "  tools/setup/bootstrap_engine.ps1 을 실행하거나 -DIRIS_ENGINE_DIR=... 로 지정하십시오.")
    endif()
    add_library(iris_jsoncpp STATIC "${_amalgam}/jsoncpp.cpp")
    target_include_directories(iris_jsoncpp PUBLIC "${_amalgam}")
    if(MSVC)
        target_compile_options(iris_jsoncpp PRIVATE -utf-8)
    endif()
    set_target_properties(iris_jsoncpp PROPERTIES FOLDER "IRIS/thirdparty")
    set(IRIS_JSON_TARGET iris_jsoncpp)
endif()

# --- iris_protocol -----------------------------------------------------------
add_library(iris_protocol STATIC
    iris/protocol/IrisbReader.h
    iris/protocol/IrisbReader.cpp
    iris/protocol/Wire.h
    iris/protocol/PipeServer.h
    iris/protocol/PipeServer.cpp
)

target_include_directories(iris_protocol PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries(iris_protocol PRIVATE ${IRIS_JSON_TARGET})

if(MSVC)
    # -utf-8 : 소스의 한글 주석 때문에 필요합니다. 대시 형식을 쓰는 이유는
    #          Git Bash/MSYS 가 /utf-8 을 경로로 번역해 버리기 때문입니다.
    target_compile_options(iris_protocol PRIVATE -utf-8 ${IRIS_WARNING_FLAGS})
endif()

set_target_properties(iris_protocol PROPERTIES FOLDER "IRIS")

# --- iris_bridge -------------------------------------------------------------
# 리더 결과를 Donut SceneGraph 로 옮기는 계층. Donut 이 있어야 하므로 **엔진
# 빌드 안에서만** 만들어집니다. 단독 빌드에서는 건너뜁니다 — iris_protocol 의
# 빠른 반복을 잃지 않기 위해서입니다.
#
# RTXPT 타입(ExtendedScene 등)에는 의존하지 않습니다. 그 접착은 엔진 쪽
# IrisScene 이 맡습니다 — 순환 의존을 만들지 않기 위한 구분입니다.
if(TARGET donut_engine)
    add_library(iris_bridge STATIC
        iris/bridge/SceneBuilder.h
        iris/bridge/SceneBuilder.cpp
        iris/bridge/IrisBridge.h
        iris/bridge/IrisBridge.cpp
    )
    target_include_directories(iris_bridge PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}")
    target_link_libraries(iris_bridge PUBLIC iris_protocol donut_engine)
    if(MSVC)
        target_compile_options(iris_bridge PRIVATE -utf-8 ${IRIS_WARNING_FLAGS})
    endif()
    set_target_properties(iris_bridge PROPERTIES FOLDER "IRIS")
else()
    message(STATUS "IRIS: donut_engine 이 없어 iris_bridge 를 건너뜁니다 (단독 빌드)")
endif()
