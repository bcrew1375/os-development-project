zig build architecture-tests -Darch=x86_32
zig build architecture-coverage -Darch=x86_32

zig build architecture-tests -Darch=x86_64
zig build architecture-coverage -Darch=x86_64

zig build tests 
zig build coverage