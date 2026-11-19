push   %rbp
push   %r15
push   %r14
push   %r13
push   %r12
push   %rbx
mov    %rsi,-0x8(%rsp)
movslq %edi,%rax
movabs $0x9e3779b97f4a7c15,%rcx
imul   %rax,%rcx
movslq 0x58(%rsp),%rdx
lock incl RIP        # ADDR <_ZL7g_ready>
nopl   0x0(%rax)
movzbl RIP,%edi        # ADDR <_ZL7g_start.0>
test   $0x1,%dil
je     ADDR <_ZL13victim_threadi6ConfigP12VictimResult+0x30>
mov    %edx,%edx
shl    $0x1e,%rdx
movabs $0x28f5c28f5c28f5c3,%rdi
mulx   %rdi,%r8,%r8
movzbl RIP,%edx        # ADDR <_ZL6g_stop.0>
test   $0x1,%dl
jne    ADDR <_ZL13victim_threadi6ConfigP12VictimResult+0x1ff>
shr    $0x2,%r8
movabs $0x1000000000000000,%r9
mov    $0xcafebabe,%edx
xor    %rdx,%rcx
cmp    $0x1,%rcx
adc    $0x0,%rcx
shl    $0x6,%rax
lea    RIP,%r14        # ADDR <_ZL8g_epochs>
add    %rax,%r14
xor    %esi,%esi
xor    %ebx,%ebx
xor    %r10d,%r10d
jmp    ADDR <_ZL13victim_threadi6ConfigP12VictimResult+0xb3>
nopw   0x0(%rax,%rax,1)
add    $0x40,%rsi
movzbl RIP,%eax        # ADDR <_ZL6g_stop.0>
test   $0x1,%al
jne    ADDR <_ZL13victim_threadi6ConfigP12VictimResult+0x206>
mov    %rsi,%r15
or     $0x1,%r15
xor    %r12d,%r12d
jmp    ADDR <_ZL13victim_threadi6ConfigP12VictimResult+0xd0>
nop
lea    (%r15,%r12,1),%rax
mov    %rax,(%r14)
inc    %r12
cmp    $0x40,%r12
je     ADDR <_ZL13victim_threadi6ConfigP12VictimResult+0xa0>
mov    %rcx,%rax
shl    $0xd,%rax
xor    %rcx,%rax
mov    %rax,%rdx
shr    $0x7,%rdx
xor    %rax,%rdx
mov    %rdx,%rcx
shl    $0x11,%rcx
xor    %rdx,%rcx
mov    %rcx,%rax
xor    %edx,%edx
divq   RIP        # ADDR <_ZL12g_table_size>
mov    RIP,%r13        # ADDR <_ZL7g_table>
mov    %rcx,%rax
shl    $0xd,%rax
xor    %rcx,%rax
mov    %rax,%rdi
shr    $0x7,%rdi
xor    %rax,%rdi
mov    %rdi,%rcx
shl    $0x11,%rcx
xor    %rdi,%rcx
mov    %rcx,%rax
shr    $0x20,%rax
shl    $0x6,%rdx
cmp    %r8,%rax
jae    ADDR <_ZL13victim_threadi6ConfigP12VictimResult+0x160>
lea    0x8(%r13,%rdx,1),%rax
jmp    ADDR <_ZL13victim_threadi6ConfigP12VictimResult+0x142>
cs nopw 0x0(%rax,%rax,1)
pause  
mov    0x8(%rax),%rdx
test   %r9,%rdx
jne    ADDR <_ZL13victim_threadi6ConfigP12VictimResult+0x140>
mov    (%rax),%rdi
mov    0x8(%rax),%r13
cmp    %r13,%rdx
jne    ADDR <_ZL13victim_threadi6ConfigP12VictimResult+0x142>
add    %rdi,%rbx
jmp    ADDR <_ZL13victim_threadi6ConfigP12VictimResult+0x1b9>
nopl   0x0(%rax)
lea    0x10(%r13,%rdx,1),%rbp
jmp    ADDR <_ZL13victim_threadi6ConfigP12VictimResult+0x172>
nopw   0x0(%rax,%rax,1)
pause  
mov    0x0(%rbp),%rdi
test   %r9,%rdi
jne    ADDR <_ZL13victim_threadi6ConfigP12VictimResult+0x170>
mov    %rdi,%r11
or     %r9,%r11
mov    %rdi,%rax
lock cmpxchg %r11,0x0(%rbp)
jne    ADDR <_ZL13victim_threadi6ConfigP12VictimResult+0x172>
mov    %rcx,%rax
shl    $0xd,%rax
xor    %rcx,%rax
mov    %rax,%r11
shr    $0x7,%r11
xor    %rax,%r11
mov    %r11,%rcx
shl    $0x11,%rcx
xor    %r11,%rcx
mov    %rcx,0x8(%r13,%rdx,1)
inc    %rdi
mov    %rdi,0x0(%rbp)
inc    %r10
mov    RIP,%rdi        # ADDR <_ZL15g_ballast_elems>
test   %rdi,%rdi
je     ADDR <_ZL13victim_threadi6ConfigP12VictimResult+0xc0>
mov    %rcx,%rax
shl    $0xd,%rax
xor    %rcx,%rax
mov    %rax,%rdx
shr    $0x7,%rdx
xor    %rax,%rdx
mov    %rdx,%rcx
shl    $0x11,%rcx
xor    %rdx,%rcx
mov    %rcx,%rax
xor    %edx,%edx
div    %rdi
mov    RIP,%rax        # ADDR <_ZL9g_ballast>
add    (%rax,%rdx,8),%rbx
jmp    ADDR <_ZL13victim_threadi6ConfigP12VictimResult+0xc0>
xor    %r10d,%r10d
xor    %ebx,%ebx
xor    %esi,%esi
mov    -0x8(%rsp),%rax
mov    %rsi,(%rax)
mov    %rbx,0x8(%rax)
mov    %r10,0x10(%rax)
pop    %rbx
pop    %r12
pop    %r13
pop    %r14
pop    %r15
pop    %rbp
ret    
