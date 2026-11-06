; Own, minimal AIR compute shader: the output must change from its sentinel.
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32"
target triple = "air64-apple-ios16.5.0"
define void @gpu_probe(ptr addrspace(1) %input, ptr addrspace(1) %output) {
  %v = load i32, ptr addrspace(1) %input, align 4
  %scaled = mul i32 %v, 3
  %result = add i32 %scaled, 7
  store i32 %result, ptr addrspace(1) %output, align 4
  ret void
}
!air.kernel = !{!0}
!air.version = !{!1}
!air.language_version = !{!2}
!0 = !{ptr @gpu_probe, !3, !4}
!1 = !{i32 2, i32 5, i32 0}
!2 = !{!"Metal", i32 3, i32 0}
!3 = !{}
!4 = !{!5, !6}
!5 = !{i32 0, !"air.buffer", !"air.location_index", i32 0, i32 1, !"air.read", !"air.address_space", i32 1, !"air.arg_type_size", i32 4, !"air.arg_type_align_size", i32 4, !"air.arg_type_name", !"uint", !"air.arg_name", !"input"}
!6 = !{i32 1, !"air.buffer", !"air.location_index", i32 1, i32 1, !"air.write", !"air.address_space", i32 1, !"air.arg_type_size", i32 4, !"air.arg_type_align_size", i32 4, !"air.arg_type_name", !"uint", !"air.arg_name", !"output"}
