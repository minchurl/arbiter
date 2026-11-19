
build/placement-diagnosis/placements/xindex-auto/binary:	file format elf64-x86-64

Disassembly of section .text:

0000000000011d00 <xindex::HGroup<Key, unsigned long>::put(Key const&, unsigned long const&)>:
   11d00: 55                           	pushq	%rbp
   11d01: 41 57                        	pushq	%r15
   11d03: 41 56                        	pushq	%r14
   11d05: 41 55                        	pushq	%r13
   11d07: 41 54                        	pushq	%r12
   11d09: 53                           	pushq	%rbx
   11d0a: 48 83 ec 38                  	subq	$0x38, %rsp
   11d0e: 48 89 54 24 18               	movq	%rdx, 0x18(%rsp)
   11d13: 49 89 f5                     	movq	%rsi, %r13
   11d16: 49 89 ff                     	movq	%rdi, %r15
   11d19: 49 be ff ff ff ff ff ff ff ef	movabsq	$-0x1000000000000001, %r14 # imm = 0xEFFFFFFFFFFFFFFF
   11d23: 48 bb 00 00 00 00 00 00 00 10	movabsq	$0x1000000000000000, %rbx # imm = 0x1000000000000000
   11d2d: 48 89 74 24 30               	movq	%rsi, 0x30(%rsp)
   11d32: 66 66 66 66 66 2e 0f 1f 84 00 00 00 00 00    	nopw	%cs:(%rax,%rax)
   11d40: 41 0f b6 7f 28               	movzbl	0x28(%r15), %edi
   11d45: 49 8b 4d 00                  	movq	(%r13), %rcx
   11d49: 62 f1 ef 08 7b c1            	vcvtusi2sd	%rcx, %xmm2, %xmm0
   11d4f: c4 c1 7b 10 0f               	vmovsd	(%r15), %xmm1
   11d54: c4 c2 f9 a9 4f 08            	vfmadd213sd	0x8(%r15), %xmm0, %xmm1 # xmm1 = (xmm0 * xmm1) + mem
   11d5a: c5 f3 5f 05 ae 32 00 00      	vmaxsd	0x32ae(%rip), %xmm1, %xmm0 # 0x15010 <_IO_stdin_used+0x10>
   11d62: 62 f1 ff 08 78 c0            	vcvttsd2usi	%xmm0, %rax
   11d68: 41 8b 57 10                  	movl	0x10(%r15), %edx
   11d6c: 8d 6a ff                     	leal	-0x1(%rdx), %ebp
   11d6f: 48 39 d0                     	cmpq	%rdx, %rax
   11d72: 48 0f 42 e8                  	cmovbq	%rax, %rbp
   11d76: 49 8b 47 18                  	movq	0x18(%r15), %rax
   11d7a: 48 c1 e5 05                  	shlq	$0x5, %rbp
   11d7e: 48 8b 14 28                  	movq	(%rax,%rbp), %rdx
   11d82: 48 85 d2                     	testq	%rdx, %rdx
   11d85: 75 43                        	jne	0x11dca <xindex::HGroup<Key, unsigned long>::put(Key const&, unsigned long const&)+0xca>
   11d87: 48 8d 54 28 10               	leaq	0x10(%rax,%rbp), %rdx
   11d8c: 0f 1f 40 00                  	nopl	(%rax)
   11d90: 48 8b 32                     	movq	(%rdx), %rsi
   11d93: 48 89 f1                     	movq	%rsi, %rcx
   11d96: 4c 21 f1                     	andq	%r14, %rcx
   11d99: 48 09 de                     	orq	%rbx, %rsi
   11d9c: 48 89 c8                     	movq	%rcx, %rax
   11d9f: f0                           	lock
   11da0: 48 0f b1 32                  	cmpxchgq	%rsi, (%rdx)
   11da4: 48 39 c8                     	cmpq	%rcx, %rax
   11da7: 75 e7                        	jne	0x11d90 <xindex::HGroup<Key, unsigned long>::put(Key const&, unsigned long const&)+0x90>
   11da9: 49 8b 47 18                  	movq	0x18(%r15), %rax
   11dad: 40 84 ff                     	testb	%dil, %dil
   11db0: 75 0b                        	jne	0x11dbd <xindex::HGroup<Key, unsigned long>::put(Key const&, unsigned long const&)+0xbd>
   11db2: 48 83 3c 28 00               	cmpq	$0x0, (%rax,%rbp)
   11db7: 0f 84 37 02 00 00            	je	0x11ff4 <xindex::HGroup<Key, unsigned long>::put(Key const&, unsigned long const&)+0x2f4>
   11dbd: 4c 21 74 28 10               	andq	%r14, 0x10(%rax,%rbp)
   11dc2: 48 8b 14 28                  	movq	(%rax,%rbp), %rdx
   11dc6: 49 8b 4d 00                  	movq	(%r13), %rcx
   11dca: 48 39 ca                     	cmpq	%rcx, %rdx
   11dcd: 0f 84 64 01 00 00            	je	0x11f37 <xindex::HGroup<Key, unsigned long>::put(Key const&, unsigned long const&)+0x237>
   11dd3: 4c 8b 64 28 18               	movq	0x18(%rax,%rbp), %r12
   11dd8: 4d 85 e4                     	testq	%r12, %r12
   11ddb: 0f 85 22 01 00 00            	jne	0x11f03 <xindex::HGroup<Key, unsigned long>::put(Key const&, unsigned long const&)+0x203>
   11de1: 48 8d 54 28 10               	leaq	0x10(%rax,%rbp), %rdx
   11de6: 66 2e 0f 1f 84 00 00 00 00 00	nopw	%cs:(%rax,%rax)
   11df0: 48 8b 32                     	movq	(%rdx), %rsi
   11df3: 48 89 f1                     	movq	%rsi, %rcx
   11df6: 4c 21 f1                     	andq	%r14, %rcx
   11df9: 48 09 de                     	orq	%rbx, %rsi
   11dfc: 48 89 c8                     	movq	%rcx, %rax
   11dff: f0                           	lock
   11e00: 48 0f b1 32                  	cmpxchgq	%rsi, (%rdx)
   11e04: 48 39 c8                     	cmpq	%rcx, %rax
   11e07: 75 e7                        	jne	0x11df0 <xindex::HGroup<Key, unsigned long>::put(Key const&, unsigned long const&)+0xf0>
   11e09: 49 8b 47 18                  	movq	0x18(%r15), %rax
   11e0d: 4c 8b 64 28 18               	movq	0x18(%rax,%rbp), %r12
   11e12: 4d 85 e4                     	testq	%r12, %r12
   11e15: 0f 85 e3 00 00 00            	jne	0x11efe <xindex::HGroup<Key, unsigned long>::put(Key const&, unsigned long const&)+0x1fe>
   11e1b: 40 88 7c 24 0f               	movb	%dil, 0xf(%rsp)
   11e20: bf 60 00 00 00               	movl	$0x60, %edi
   11e25: be 40 00 00 00               	movl	$0x40, %esi
   11e2a: ba 63 00 00 00               	movl	$0x63, %edx
   11e2f: 31 c9                        	xorl	%ecx, %ecx
   11e31: e8 7a 09 00 00               	callq	0x127b0 <arbiter_new_site>
   11e36: 49 89 c4                     	movq	%rax, %r12
   11e39: c5 f9 57 c0                  	vxorpd	%xmm0, %xmm0, %xmm0
   11e3d: c5 f9 11 00                  	vmovupd	%xmm0, (%rax)
   11e41: c5 f9 57 c0                  	vxorpd	%xmm0, %xmm0, %xmm0
   11e45: c5 fd 11 40 18               	vmovupd	%ymm0, 0x18(%rax)
   11e4a: c5 fd 11 40 38               	vmovupd	%ymm0, 0x38(%rax)
   11e4f: 48 c7 40 58 00 00 00 00      	movq	$0x0, 0x58(%rax)
   11e57: 31 c0                        	xorl	%eax, %eax
   11e59: 41 87 44 24 10               	xchgl	%eax, 0x10(%r12)
   11e5e: 49 c7 44 24 58 00 00 00 00   	movq	$0x0, 0x58(%r12)
   11e67: bf 08 00 00 00               	movl	$0x8, %edi
   11e6c: be 40 00 00 00               	movl	$0x40, %esi
   11e71: ba 64 00 00 00               	movl	$0x64, %edx
   11e76: 31 c9                        	xorl	%ecx, %ecx
   11e78: c5 f8 77                     	vzeroupper
   11e7b: e8 30 09 00 00               	callq	0x127b0 <arbiter_new_site>
   11e80: 49 89 c5                     	movq	%rax, %r13
   11e83: 49 8b 44 24 40               	movq	0x40(%r12), %rax
   11e88: 49 8b 54 24 48               	movq	0x48(%r12), %rdx
   11e8d: 48 29 c2                     	subq	%rax, %rdx
   11e90: 48 85 d2                     	testq	%rdx, %rdx
   11e93: 7e 17                        	jle	0x11eac <xindex::HGroup<Key, unsigned long>::put(Key const&, unsigned long const&)+0x1ac>
   11e95: 4c 89 ef                     	movq	%r13, %rdi
   11e98: 48 89 44 24 28               	movq	%rax, 0x28(%rsp)
   11e9d: 48 8b 74 24 28               	movq	0x28(%rsp), %rsi
   11ea2: e8 e9 11 ff ff               	callq	0x3090 <memmove@plt>
   11ea7: 48 8b 44 24 28               	movq	0x28(%rsp), %rax
   11eac: 48 85 c0                     	testq	%rax, %rax
   11eaf: 74 08                        	je	0x11eb9 <xindex::HGroup<Key, unsigned long>::put(Key const&, unsigned long const&)+0x1b9>
   11eb1: 48 89 c7                     	movq	%rax, %rdi
   11eb4: e8 67 0c 00 00               	callq	0x12b20 <arbiter_cxx_delete_maybe>
   11eb9: 4d 89 6c 24 40               	movq	%r13, 0x40(%r12)
   11ebe: 4d 89 6c 24 48               	movq	%r13, 0x48(%r12)
   11ec3: 49 83 c5 08                  	addq	$0x8, %r13
   11ec7: 4d 89 6c 24 50               	movq	%r13, 0x50(%r12)
   11ecc: 4c 89 e7                     	movq	%r12, %rdi
   11ecf: e8 ac 91 ff ff               	callq	0xb080 <xindex::AltBtreeBuffer<Key, unsigned long>::allocate_leaf()>
   11ed4: 49 89 44 24 08               	movq	%rax, 0x8(%r12)
   11ed9: c6 00 01                     	movb	$0x1, (%rax)
   11edc: c6 40 02 00                  	movb	$0x0, 0x2(%rax)
   11ee0: 49 89 04 24                  	movq	%rax, (%r12)
   11ee4: 31 c0                        	xorl	%eax, %eax
   11ee6: 41 87 44 24 10               	xchgl	%eax, 0x10(%r12)
   11eeb: 49 8b 47 18                  	movq	0x18(%r15), %rax
   11eef: 4c 89 64 28 18               	movq	%r12, 0x18(%rax,%rbp)
   11ef4: 4c 8b 6c 24 30               	movq	0x30(%rsp), %r13
   11ef9: 0f b6 7c 24 0f               	movzbl	0xf(%rsp), %edi
   11efe: 4c 21 74 28 10               	andq	%r14, 0x10(%rax,%rbp)
   11f03: 40 84 ff                     	testb	%dil, %dil
   11f06: 74 43                        	je	0x11f4b <xindex::HGroup<Key, unsigned long>::put(Key const&, unsigned long const&)+0x24b>
   11f08: 4c 89 e7                     	movq	%r12, %rdi
   11f0b: 4c 89 ee                     	movq	%r13, %rsi
   11f0e: 48 8b 54 24 18               	movq	0x18(%rsp), %rdx
   11f13: e8 28 01 00 00               	callq	0x12040 <xindex::AltBtreeBuffer<Key, unsigned long>::update(Key const&, unsigned long const&)>
   11f18: 84 c0                        	testb	%al, %al
   11f1a: 0f 85 c3 00 00 00            	jne	0x11fe3 <xindex::HGroup<Key, unsigned long>::put(Key const&, unsigned long const&)+0x2e3>
   11f20: 4d 8b 7f 20                  	movq	0x20(%r15), %r15
   11f24: 4d 85 ff                     	testq	%r15, %r15
   11f27: 0f 85 13 fe ff ff            	jne	0x11d40 <xindex::HGroup<Key, unsigned long>::put(Key const&, unsigned long const&)+0x40>
   11f2d: b8 02 00 00 00               	movl	$0x2, %eax
   11f32: e9 ae 00 00 00               	jmp	0x11fe5 <xindex::HGroup<Key, unsigned long>::put(Key const&, unsigned long const&)+0x2e5>
   11f37: 48 8d 7c 28 08               	leaq	0x8(%rax,%rbp), %rdi
   11f3c: 48 8b 74 24 18               	movq	0x18(%rsp), %rsi
   11f41: e8 ca 96 ff ff               	callq	0xb610 <xindex::AtomicVal<unsigned long>::update(unsigned long const&)>
   11f46: e9 98 00 00 00               	jmp	0x11fe3 <xindex::HGroup<Key, unsigned long>::put(Key const&, unsigned long const&)+0x2e3>
   11f4b: 49 8b 5d 00                  	movq	(%r13), %rbx
   11f4f: 48 89 5c 24 20               	movq	%rbx, 0x20(%rsp)
   11f54: 48 8d 74 24 20               	leaq	0x20(%rsp), %rsi
   11f59: 48 8d 54 24 10               	leaq	0x10(%rsp), %rdx
   11f5e: 4c 89 e7                     	movq	%r12, %rdi
   11f61: e8 ba 95 ff ff               	callq	0xb520 <xindex::AltBtreeBuffer<Key, unsigned long>::locate_leaf(Key, unsigned long&)>
   11f66: 48 89 c1                     	movq	%rax, %rcx
   11f69: b2 01                        	movb	$0x1, %dl
   11f6b: 0f 1f 44 00 00               	nopl	(%rax,%rax)
   11f70: 31 c0                        	xorl	%eax, %eax
   11f72: f0                           	lock
   11f73: 0f b0 51 01                  	cmpxchgb	%dl, 0x1(%rcx)
   11f77: 84 c0                        	testb	%al, %al
   11f79: 75 f5                        	jne	0x11f70 <xindex::HGroup<Key, unsigned long>::put(Key const&, unsigned long const&)+0x270>
   11f7b: 48 8b 44 24 10               	movq	0x10(%rsp), %rax
   11f80: 48 3b 41 08                  	cmpq	0x8(%rcx), %rax
   11f84: 74 4d                        	je	0x11fd3 <xindex::HGroup<Key, unsigned long>::put(Key const&, unsigned long const&)+0x2d3>
   11f86: c6 41 01 00                  	movb	$0x0, 0x1(%rcx)
   11f8a: 48 8b 41 08                  	movq	0x8(%rcx), %rax
   11f8e: 48 89 44 24 10               	movq	%rax, 0x10(%rsp)
   11f93: 0f ae f0                     	mfence
   11f96: 48 8b 41 60                  	movq	0x60(%rcx), %rax
   11f9a: 48 85 c0                     	testq	%rax, %rax
   11f9d: 74 d1                        	je	0x11f70 <xindex::HGroup<Key, unsigned long>::put(Key const&, unsigned long const&)+0x270>
   11f9f: 48 39 58 10                  	cmpq	%rbx, 0x10(%rax)
   11fa3: 77 cb                        	ja	0x11f70 <xindex::HGroup<Key, unsigned long>::put(Key const&, unsigned long const&)+0x270>
   11fa5: 66 66 2e 0f 1f 84 00 00 00 00 00     	nopw	%cs:(%rax,%rax)
   11fb0: 48 8b 48 08                  	movq	0x8(%rax), %rcx
   11fb4: 48 89 4c 24 10               	movq	%rcx, 0x10(%rsp)
   11fb9: 0f ae f0                     	mfence
   11fbc: 48 8b 70 60                  	movq	0x60(%rax), %rsi
   11fc0: 48 89 c1                     	movq	%rax, %rcx
   11fc3: 48 85 f6                     	testq	%rsi, %rsi
   11fc6: 74 a8                        	je	0x11f70 <xindex::HGroup<Key, unsigned long>::put(Key const&, unsigned long const&)+0x270>
   11fc8: 48 89 f0                     	movq	%rsi, %rax
   11fcb: 48 39 5e 10                  	cmpq	%rbx, 0x10(%rsi)
   11fcf: 76 df                        	jbe	0x11fb0 <xindex::HGroup<Key, unsigned long>::put(Key const&, unsigned long const&)+0x2b0>
   11fd1: eb 9d                        	jmp	0x11f70 <xindex::HGroup<Key, unsigned long>::put(Key const&, unsigned long const&)+0x270>
   11fd3: 4c 89 e7                     	movq	%r12, %rdi
   11fd6: 4c 89 ee                     	movq	%r13, %rsi
   11fd9: 48 8b 54 24 18               	movq	0x18(%rsp), %rdx
   11fde: e8 cd 92 ff ff               	callq	0xb2b0 <xindex::AltBtreeBuffer<Key, unsigned long>::insert_leaf(Key const&, unsigned long const&, xindex::AltBtreeBuffer<Key, unsigned long>::Leaf*)>
   11fe3: 31 c0                        	xorl	%eax, %eax
   11fe5: 48 83 c4 38                  	addq	$0x38, %rsp
   11fe9: 5b                           	popq	%rbx
   11fea: 41 5c                        	popq	%r12
   11fec: 41 5d                        	popq	%r13
   11fee: 41 5e                        	popq	%r14
   11ff0: 41 5f                        	popq	%r15
   11ff2: 5d                           	popq	%rbp
   11ff3: c3                           	retq
   11ff4: 48 8b 4c 24 18               	movq	0x18(%rsp), %rcx
   11ff9: 48 8b 09                     	movq	(%rcx), %rcx
   11ffc: 48 89 4c 24 10               	movq	%rcx, 0x10(%rsp)
   12001: 48 c7 44 24 20 00 00 00 00   	movq	$0x0, 0x20(%rsp)
   1200a: 48 8b 4c 24 10               	movq	0x10(%rsp), %rcx
   1200f: 48 89 4c 28 08               	movq	%rcx, 0x8(%rax,%rbp)
   12014: 48 8b 4c 24 20               	movq	0x20(%rsp), %rcx
   12019: 48 89 4c 28 10               	movq	%rcx, 0x10(%rax,%rbp)
   1201e: 49 8b 47 18                  	movq	0x18(%r15), %rax
   12022: 49 8b 4d 00                  	movq	(%r13), %rcx
   12026: 48 89 0c 28                  	movq	%rcx, (%rax,%rbp)
   1202a: f0                           	lock
   1202b: 41 ff 47 14                  	incl	0x14(%r15)
   1202f: 49 8b 47 18                  	movq	0x18(%r15), %rax
   12033: 4c 21 74 28 10               	andq	%r14, 0x10(%rax,%rbp)
   12038: eb a9                        	jmp	0x11fe3 <xindex::HGroup<Key, unsigned long>::put(Key const&, unsigned long const&)+0x2e3>
