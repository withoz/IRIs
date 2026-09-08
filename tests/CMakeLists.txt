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

# 실제 프로젝트 모델로 돕니다. 합성 데이터로는 놓치는 것이 있습니다.
set(IRIS_TEST_SCENE
    "${CMAKE_SOURCE_DIR}/out/sketchup/240925_포르쉐_성수_PSC_10F_골프존.irisb"
    CACHE FILEPATH "리더 시험에 쓸 .irisb 파일")

if(EXISTS "${IRIS_TEST_SCENE}")
    add_test(NAME irisb_reader COMMAND test_irisb_reader "${IRIS_TEST_SCENE}")
else()
    message(STATUS "IRIS: 시험용 씬이 없어 irisb_reader 시험을 등록하지 않습니다: ${IRIS_TEST_SCENE}")
endif()
