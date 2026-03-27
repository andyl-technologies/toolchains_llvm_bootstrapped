extern "C" {
    fn concatenated_length(a: *const std::ffi::c_char, b: *const std::ffi::c_char) -> i32;
}

fn main() {
    let a = c"Hello, ";
    let b = c"world!";
    let len = unsafe { concatenated_length(a.as_ptr(), b.as_ptr()) };
    assert_eq!(len, 13, "Expected 13, got {len}");
    println!("rust_cpp_ffi: concatenated_length = {len}");
}
