# 시험 실행 파일.
#
# 프레임워크를 쓰지 않습니다. 실제 씬 파일 하나로 도는 프로그램이면 충분하고,
# 의존성을 늘리지 않는 편이 낫습니다.

add_executable(test_irisb_reader test_irisb_reader.cpp)
target_link_libraries(test_irisb_reader PRIVATE iris_protocol)

if(MSVC)
    target_compile_options(test_irisb_reader PRIVATE -utf-8 ${IRIS_WARNING_FLAGS})
endif()

set_target_properties(test_irisb_reader PROPERTIES FOLDER "IRIS/tests")

add_executable(test_pipe_server test_pipe_server.cpp)
target_link_libraries(test_pipe_server PRIVATE iris_protocol)
if(MSVC)
    target_compile_options(test_pipe_server PRIVATE -utf-8 ${IRIS_WARNING_FLAGS})
endif()
set_target_properties(test_pipe_server PROPERTIES FOLDER "IRIS/tests")

# 실제 프로젝트 모델로 돕니다. 합성 데이터로는 놓치는 것이 있습니다.
set(IRIS_TEST_SCENE
    "${CMAKE_SOURCE_DIR}/out/sketchup/240925_포르쉐_성수_PSC_10F_골프존.irisb"
    CACHE FILEPATH "리더 시험에 쓸 .irisb 파일")

if(EXISTS "${IRIS_TEST_SCENE}")
    add_test(NAME irisb_reader COMMAND test_irisb_reader "${IRIS_TEST_SCENE}")
    add_test(NAME pipe_server  COMMAND test_pipe_server  "${IRIS_TEST_SCENE}")
else()
    message(STATUS "IRIS: 시험용 씬이 없어 irisb_reader 시험을 등록하지 않습니다: ${IRIS_TEST_SCENE}")
endif()

# 합성 배선 씬.
#
# 실제 모델은 사용자가 편집하면 내용이 바뀝니다. 조명·PBR 처럼 **없어도
# 오류가 안 나는** 기능은 그것만으로 시험하면 어느 날 조용히 0이 되어도
# 모릅니다. 값이 고정된 씬이 하나 있어야 합니다.
#
# 생성:  python tools/rtxpt/iris_make_test_scene.py out/test/wiring.irisb
set(IRIS_WIRING_SCENE "${CMAKE_SOURCE_DIR}/out/test/wiring.irisb")
if(EXISTS "${IRIS_WIRING_SCENE}")
    add_test(NAME irisb_wiring COMMAND test_irisb_reader "${IRIS_WIRING_SCENE}")
else()
    message(STATUS "IRIS: 배선 시험 씬이 없습니다 (tools/rtxpt/iris_make_test_scene.py 로 생성): ${IRIS_WIRING_SCENE}")
endif()
