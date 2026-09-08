# IRIS 고유 코드.
#
# 엔진(RTXPT 포크)에 의존하지 않는 계층부터 쌓습니다. iris_protocol 은
# Donut/nvrhi 를 전혀 모르므로 단독으로 빌드하고 시험할 수 있습니다.
# 엔진과 만나는 것은 나중에 추가할 iris_bridge 입니다.

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
)

target_include_directories(iris_protocol PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries(iris_protocol PRIVATE ${IRIS_JSON_TARGET})

if(MSVC)
    # -utf-8 : 소스의 한글 주석 때문에 필요합니다. 대시 형식을 쓰는 이유는
    #          Git Bash/MSYS 가 /utf-8 을 경로로 번역해 버리기 때문입니다.
    # /W4 /WX: 우리 코드에만 겁니다. 서드파티에는 걸지 않습니다.
    target_compile_options(iris_protocol PRIVATE -utf-8 /W4 /WX)
endif()

set_target_properties(iris_protocol PROPERTIES FOLDER "IRIS")
