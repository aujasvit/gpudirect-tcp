add_executable(bench_redirect "bench_redirect.c")
add_executable(bench_server "bench_server.c")
add_executable(bench_native "bench_native.c")
add_executable(bench_host "bench_host.cu")

target_compile_options(bench_redirect PRIVATE -O2 -Wno-unused-result)
target_compile_options(bench_server PRIVATE -O2 -Wno-unused-result)
target_compile_options(bench_native PRIVATE -O2 -Wno-unused-result)

target_link_libraries(bench_host PRIVATE cuda)

set_target_properties(bench_host PROPERTIES
    CUDA_SEPARABLE_COMPILATION ON
)

install(TARGETS bench_redirect DESTINATION ${PROJECT_BINARY_DIR})
install(TARGETS bench_server DESTINATION ${PROJECT_BINARY_DIR})
install(TARGETS bench_native DESTINATION ${PROJECT_BINARY_DIR})
install(TARGETS bench_host DESTINATION ${PROJECT_BINARY_DIR})
