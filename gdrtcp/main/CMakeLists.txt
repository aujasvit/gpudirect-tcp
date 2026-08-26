add_executable(bench_gdrtcp 
    "helpers.cuh"
    "gdrtcp.cu"
    "gdrtcp.h"
    "gdr_common.h"
    "bench_gdrtcp.cu"
)

target_compile_options(bench_gdrtcp PRIVATE
	    $<$<COMPILE_LANGUAGE:CUDA>:-O2>
	        $<$<COMPILE_LANGUAGE:CUDA>:-Xcompiler=-O2>
		)

target_link_libraries(bench_gdrtcp PRIVATE cuda)

set_target_properties(bench_gdrtcp PROPERTIES
    CUDA_SEPARABLE_COMPILATION ON
)

install(TARGETS bench_gdrtcp DESTINATION ${PROJECT_BINARY_DIR})


