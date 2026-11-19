
build/placement-diagnosis/placements/xindex-buffer/binary:	file format elf64-x86-64

Disassembly of section .text:

0000000000011ce0 <xindex::HGroup<Key, unsigned long>::put(Key const&, unsigned long const&)>:
   11ce0: 55                           	pushq	%rbp
   11ce1: 41 57                        	pushq	%r15
   11ce3: 41 56                        	pushq	%r14
   11ce5: 41 55                        	pushq	%r13
   11ce7: 41 54                        	pushq	%r12
   11ce9: 53                           	pushq	%rbx
   11cea: 48 83 ec 38                  	subq	$0x38, %rsp
   11cee: 48 89 54 24 18               	movq	%rdx, 0x18(%rsp)
   11cf3: 49 89 f5                     	movq	%rsi, %r13
   11cf6: 49 89 ff                     	movq	%rdi, %r15
   11cf9: 49 be ff ff ff ff ff ff ff ef	movabsq	$-0x1000000000000001, %r14 # imm = 0xEFFFFFFFFFFFFFFF
   11d03: 48 bb 00 00 00 00 00 00 00 10	movabsq	$0x1000000000000000, %rbx # imm = 0x1000000000000000
   11d0d: 48 89 74 24 30               	movq	%rsi, 0x30(%rsp)
   11d12: 66 66 66 66 66 2e 0f 1f 84 00 00 00 00 00    	nopw	%cs:(%rax,%rax)
   11d20: 41 0f b6 7f 28               	movzbl	0x28(%r15), %edi
   11d25: 49 8b 4d 00                  	movq	(%r13), %rcx
   11d29: 62 f1 ef 08 7b c1            	vcvtusi2sd	%rcx, %xmm2, %xmm0
   11d2f: c4 c1 7b 10 0f               	vmovsd	(%r15), %xmm1
   11d34: c4 c2 f9 a9 4f 08            	vfmadd213sd	0x8(%r15), %xmm0, %xmm1 # xmm1 = (xmm0 * xmm1) + mem
   11d3a: c5 f3 5f 05 ce 32 00 00      	vmaxsd	0x32ce(%rip), %xmm1, %xmm0 # 0x15010 <_IO_stdin_used+0x10>
   11d42: 62 f1 ff 08 78 c0            	vcvttsd2usi	%xmm0, %rax
   11d48: 41 8b 57 10                  	movl	0x10(%r15), %edx
   11d4c: 8d 6a ff                     	leal	-0x1(%rdx), %ebp
   11d4f: 48 39 d0                     	cmpq	%rdx, %rax
   11d52: 48 0f 42 e8                  	cmovbq	%rax, %rbp
   11d56: 49 8b 47 18                  	movq	0x18(%r15), %rax
   11d5a: 48 c1 e5 05                  	shlq	$0x5, %rbp
   11d5e: 48 8b 14 28                  	movq	(%rax,%rbp), %rdx
   11d62: 48 85 d2                     	testq	%rdx, %rdx
   11d65: 75 43                        	jne	0x11daa <xindex::HGroup<Key, unsigned long>::put(Key const&, unsigned long const&)+0xca>
   11d67: 48 8d 54 28 10               	leaq	0x10(%rax,%rbp), %rdx
   11d6c: 0f 1f 40 00                  	nopl	(%rax)
   11d70: 48 8b 32                     	movq	(%rdx), %rsi
   11d73: 48 89 f1                     	movq	%rsi, %rcx
   11d76: 4c 21 f1                     	andq	%r14, %rcx
   11d79: 48 09 de                     	orq	%rbx, %rsi
   11d7c: 48 89 c8                     	movq	%rcx, %rax
   11d7f: f0                           	lock
   11d80: 48 0f b1 32                  	cmpxchgq	%rsi, (%rdx)
   11d84: 48 39 c8                     	cmpq	%rcx, %rax
   11d87: 75 e7                        	jne	0x11d70 <xindex::HGroup<Key, unsigned long>::put(Key const&, unsigned long const&)+0x90>
   11d89: 49 8b 47 18                  	movq	0x18(%r15), %rax
   11d8d: 40 84 ff                     	testb	%dil, %dil
   11d90: 75 0b                        	jne	0x11d9d <xindex::HGroup<Key, unsigned long>::put(Key const&, unsigned long const&)+0xbd>
   11d92: 48 83 3c 28 00               	cmpq	$0x0, (%rax,%rbp)
   11d97: 0f 84 27 02 00 00            	je	0x11fc4 <xindex::HGroup<Key, unsigned long>::put(Key const&, unsigned long const&)+0x2e4>
   11d9d: 4c 21 74 28 10               	andq	%r14, 0x10(%rax,%rbp)
   11da2: 48 8b 14 28                  	movq	(%rax,%rbp), %rdx
   11da6: 49 8b 4d 00                  	movq	(%r13), %rcx
   11daa: 48 39 ca                     	cmpq	%rcx, %rdx
   11dad: 0f 84 4c 01 00 00            	je	0x11eff <xindex::HGroup<Key, unsigned long>::put(Key const&, unsigned long const&)+0x21f>
   11db3: 4c 8b 64 28 18               	movq	0x18(%rax,%rbp), %r12
   11db8: 4d 85 e4                     	testq	%r12, %r12
   11dbb: 0f 85 0a 01 00 00            	jne	0x11ecb <xindex::HGroup<Key, unsigned long>::put(Key const&, unsigned long const&)+0x1eb>
   11dc1: 48 8d 54 28 10               	leaq	0x10(%rax,%rbp), %rdx
   11dc6: 66 2e 0f 1f 84 00 00 00 00 00	nopw	%cs:(%rax,%rax)
   11dd0: 48 8b 32                     	movq	(%rdx), %rsi
   11dd3: 48 89 f1                     	movq	%rsi, %rcx
   11dd6: 4c 21 f1                     	andq	%r14, %rcx
   11dd9: 48 09 de                     	orq	%rbx, %rsi
   11ddc: 48 89 c8                     	movq	%rcx, %rax
   11ddf: f0                           	lock
   11de0: 48 0f b1 32                  	cmpxchgq	%rsi, (%rdx)
   11de4: 48 39 c8                     	cmpq	%rcx, %rax
   11de7: 75 e7                        	jne	0x11dd0 <xindex::HGroup<Key, unsigned long>::put(Key const&, unsigned long const&)+0xf0>
   11de9: 49 8b 47 18                  	movq	0x18(%r15), %rax
   11ded: 4c 8b 64 28 18               	movq	0x18(%rax,%rbp), %r12
   11df2: 4d 85 e4                     	testq	%r12, %r12
   11df5: 0f 85 cb 00 00 00            	jne	0x11ec6 <xindex::HGroup<Key, unsigned long>::put(Key const&, unsigned long const&)+0x1e6>
   11dfb: 40 88 7c 24 0f               	movb	%dil, 0xf(%rsp)
   11e00: bf 60 00 00 00               	movl	$0x60, %edi
   11e05: e8 76 15 ff ff               	callq	0x3380 <_Znwm@plt>
   11e0a: 49 89 c4                     	movq	%rax, %r12
   11e0d: c5 f9 57 c0                  	vxorpd	%xmm0, %xmm0, %xmm0
   11e11: c5 f9 11 00                  	vmovupd	%xmm0, (%rax)
   11e15: c5 f9 57 c0                  	vxorpd	%xmm0, %xmm0, %xmm0
   11e19: c5 fd 11 40 18               	vmovupd	%ymm0, 0x18(%rax)
   11e1e: c5 fd 11 40 38               	vmovupd	%ymm0, 0x38(%rax)
   11e23: 48 c7 40 58 00 00 00 00      	movq	$0x0, 0x58(%rax)
   11e2b: 31 c0                        	xorl	%eax, %eax
   11e2d: 41 87 44 24 10               	xchgl	%eax, 0x10(%r12)
   11e32: 49 c7 44 24 58 00 00 00 00   	movq	$0x0, 0x58(%r12)
   11e3b: bf 08 00 00 00               	movl	$0x8, %edi
   11e40: c5 f8 77                     	vzeroupper
   11e43: e8 38 15 ff ff               	callq	0x3380 <_Znwm@plt>
   11e48: 49 89 c5                     	movq	%rax, %r13
   11e4b: 49 8b 44 24 40               	movq	0x40(%r12), %rax
   11e50: 49 8b 54 24 48               	movq	0x48(%r12), %rdx
   11e55: 48 29 c2                     	subq	%rax, %rdx
   11e58: 48 85 d2                     	testq	%rdx, %rdx
   11e5b: 7e 17                        	jle	0x11e74 <xindex::HGroup<Key, unsigned long>::put(Key const&, unsigned long const&)+0x194>
   11e5d: 4c 89 ef                     	movq	%r13, %rdi
   11e60: 48 89 44 24 28               	movq	%rax, 0x28(%rsp)
   11e65: 48 8b 74 24 28               	movq	0x28(%rsp), %rsi
   11e6a: e8 21 12 ff ff               	callq	0x3090 <memmove@plt>
   11e6f: 48 8b 44 24 28               	movq	0x28(%rsp), %rax
   11e74: 48 85 c0                     	testq	%rax, %rax
   11e77: 74 08                        	je	0x11e81 <xindex::HGroup<Key, unsigned long>::put(Key const&, unsigned long const&)+0x1a1>
   11e79: 48 89 c7                     	movq	%rax, %rdi
   11e7c: e8 6f 0c 00 00               	callq	0x12af0 <arbiter_cxx_delete_maybe>
   11e81: 4d 89 6c 24 40               	movq	%r13, 0x40(%r12)
   11e86: 4d 89 6c 24 48               	movq	%r13, 0x48(%r12)
   11e8b: 49 83 c5 08                  	addq	$0x8, %r13
   11e8f: 4d 89 6c 24 50               	movq	%r13, 0x50(%r12)
   11e94: 4c 89 e7                     	movq	%r12, %rdi
   11e97: e8 f4 91 ff ff               	callq	0xb090 <xindex::AltBtreeBuffer<Key, unsigned long>::allocate_leaf()>
   11e9c: 49 89 44 24 08               	movq	%rax, 0x8(%r12)
   11ea1: c6 00 01                     	movb	$0x1, (%rax)
   11ea4: c6 40 02 00                  	movb	$0x0, 0x2(%rax)
   11ea8: 49 89 04 24                  	movq	%rax, (%r12)
   11eac: 31 c0                        	xorl	%eax, %eax
   11eae: 41 87 44 24 10               	xchgl	%eax, 0x10(%r12)
   11eb3: 49 8b 47 18                  	movq	0x18(%r15), %rax
   11eb7: 4c 89 64 28 18               	movq	%r12, 0x18(%rax,%rbp)
   11ebc: 4c 8b 6c 24 30               	movq	0x30(%rsp), %r13
   11ec1: 0f b6 7c 24 0f               	movzbl	0xf(%rsp), %edi
   11ec6: 4c 21 74 28 10               	andq	%r14, 0x10(%rax,%rbp)
   11ecb: 40 84 ff                     	testb	%dil, %dil
   11ece: 74 43                        	je	0x11f13 <xindex::HGroup<Key, unsigned long>::put(Key const&, unsigned long const&)+0x233>
   11ed0: 4c 89 e7                     	movq	%r12, %rdi
   11ed3: 4c 89 ee                     	movq	%r13, %rsi
   11ed6: 48 8b 54 24 18               	movq	0x18(%rsp), %rdx
   11edb: e8 30 01 00 00               	callq	0x12010 <xindex::AltBtreeBuffer<Key, unsigned long>::update(Key const&, unsigned long const&)>
   11ee0: 84 c0                        	testb	%al, %al
   11ee2: 0f 85 cb 00 00 00            	jne	0x11fb3 <xindex::HGroup<Key, unsigned long>::put(Key const&, unsigned long const&)+0x2d3>
   11ee8: 4d 8b 7f 20                  	movq	0x20(%r15), %r15
   11eec: 4d 85 ff                     	testq	%r15, %r15
   11eef: 0f 85 2b fe ff ff            	jne	0x11d20 <xindex::HGroup<Key, unsigned long>::put(Key const&, unsigned long const&)+0x40>
   11ef5: b8 02 00 00 00               	movl	$0x2, %eax
   11efa: e9 b6 00 00 00               	jmp	0x11fb5 <xindex::HGroup<Key, unsigned long>::put(Key const&, unsigned long const&)+0x2d5>
   11eff: 48 8d 7c 28 08               	leaq	0x8(%rax,%rbp), %rdi
   11f04: 48 8b 74 24 18               	movq	0x18(%rsp), %rsi
   11f09: e8 02 97 ff ff               	callq	0xb610 <xindex::AtomicVal<unsigned long>::update(unsigned long const&)>
   11f0e: e9 a0 00 00 00               	jmp	0x11fb3 <xindex::HGroup<Key, unsigned long>::put(Key const&, unsigned long const&)+0x2d3>
   11f13: 49 8b 5d 00                  	movq	(%r13), %rbx
   11f17: 48 89 5c 24 20               	movq	%rbx, 0x20(%rsp)
   11f1c: 48 8d 74 24 20               	leaq	0x20(%rsp), %rsi
   11f21: 48 8d 54 24 10               	leaq	0x10(%rsp), %rdx
   11f26: 4c 89 e7                     	movq	%r12, %rdi
   11f29: e8 f2 95 ff ff               	callq	0xb520 <xindex::AltBtreeBuffer<Key, unsigned long>::locate_leaf(Key, unsigned long&)>
   11f2e: 48 89 c1                     	movq	%rax, %rcx
   11f31: b2 01                        	movb	$0x1, %dl
   11f33: 66 66 66 66 2e 0f 1f 84 00 00 00 00 00       	nopw	%cs:(%rax,%rax)
   11f40: 31 c0                        	xorl	%eax, %eax
   11f42: f0                           	lock
   11f43: 0f b0 51 01                  	cmpxchgb	%dl, 0x1(%rcx)
   11f47: 84 c0                        	testb	%al, %al
   11f49: 75 f5                        	jne	0x11f40 <xindex::HGroup<Key, unsigned long>::put(Key const&, unsigned long const&)+0x260>
   11f4b: 48 8b 44 24 10               	movq	0x10(%rsp), %rax
   11f50: 48 3b 41 08                  	cmpq	0x8(%rcx), %rax
   11f54: 74 4d                        	je	0x11fa3 <xindex::HGroup<Key, unsigned long>::put(Key const&, unsigned long const&)+0x2c3>
   11f56: c6 41 01 00                  	movb	$0x0, 0x1(%rcx)
   11f5a: 48 8b 41 08                  	movq	0x8(%rcx), %rax
   11f5e: 48 89 44 24 10               	movq	%rax, 0x10(%rsp)
   11f63: 0f ae f0                     	mfence
   11f66: 48 8b 41 60                  	movq	0x60(%rcx), %rax
   11f6a: 48 85 c0                     	testq	%rax, %rax
   11f6d: 74 d1                        	je	0x11f40 <xindex::HGroup<Key, unsigned long>::put(Key const&, unsigned long const&)+0x260>
   11f6f: 48 39 58 10                  	cmpq	%rbx, 0x10(%rax)
   11f73: 77 cb                        	ja	0x11f40 <xindex::HGroup<Key, unsigned long>::put(Key const&, unsigned long const&)+0x260>
   11f75: 66 66 2e 0f 1f 84 00 00 00 00 00     	nopw	%cs:(%rax,%rax)
   11f80: 48 8b 48 08                  	movq	0x8(%rax), %rcx
   11f84: 48 89 4c 24 10               	movq	%rcx, 0x10(%rsp)
   11f89: 0f ae f0                     	mfence
   11f8c: 48 8b 70 60                  	movq	0x60(%rax), %rsi
   11f90: 48 89 c1                     	movq	%rax, %rcx
   11f93: 48 85 f6                     	testq	%rsi, %rsi
   11f96: 74 a8                        	je	0x11f40 <xindex::HGroup<Key, unsigned long>::put(Key const&, unsigned long const&)+0x260>
   11f98: 48 89 f0                     	movq	%rsi, %rax
   11f9b: 48 39 5e 10                  	cmpq	%rbx, 0x10(%rsi)
   11f9f: 76 df                        	jbe	0x11f80 <xindex::HGroup<Key, unsigned long>::put(Key const&, unsigned long const&)+0x2a0>
   11fa1: eb 9d                        	jmp	0x11f40 <xindex::HGroup<Key, unsigned long>::put(Key const&, unsigned long const&)+0x260>
   11fa3: 4c 89 e7                     	movq	%r12, %rdi
   11fa6: 4c 89 ee                     	movq	%r13, %rsi
   11fa9: 48 8b 54 24 18               	movq	0x18(%rsp), %rdx
   11fae: e8 fd 92 ff ff               	callq	0xb2b0 <xindex::AltBtreeBuffer<Key, unsigned long>::insert_leaf(Key const&, unsigned long const&, xindex::AltBtreeBuffer<Key, unsigned long>::Leaf*)>
   11fb3: 31 c0                        	xorl	%eax, %eax
   11fb5: 48 83 c4 38                  	addq	$0x38, %rsp
   11fb9: 5b                           	popq	%rbx
   11fba: 41 5c                        	popq	%r12
   11fbc: 41 5d                        	popq	%r13
   11fbe: 41 5e                        	popq	%r14
   11fc0: 41 5f                        	popq	%r15
   11fc2: 5d                           	popq	%rbp
   11fc3: c3                           	retq
   11fc4: 48 8b 4c 24 18               	movq	0x18(%rsp), %rcx
   11fc9: 48 8b 09                     	movq	(%rcx), %rcx
   11fcc: 48 89 4c 24 10               	movq	%rcx, 0x10(%rsp)
   11fd1: 48 c7 44 24 20 00 00 00 00   	movq	$0x0, 0x20(%rsp)
   11fda: 48 8b 4c 24 10               	movq	0x10(%rsp), %rcx
   11fdf: 48 89 4c 28 08               	movq	%rcx, 0x8(%rax,%rbp)
   11fe4: 48 8b 4c 24 20               	movq	0x20(%rsp), %rcx
   11fe9: 48 89 4c 28 10               	movq	%rcx, 0x10(%rax,%rbp)
   11fee: 49 8b 47 18                  	movq	0x18(%r15), %rax
   11ff2: 49 8b 4d 00                  	movq	(%r13), %rcx
   11ff6: 48 89 0c 28                  	movq	%rcx, (%rax,%rbp)
   11ffa: f0                           	lock
   11ffb: 41 ff 47 14                  	incl	0x14(%r15)
   11fff: 49 8b 47 18                  	movq	0x18(%r15), %rax
   12003: 4c 21 74 28 10               	andq	%r14, 0x10(%rax,%rbp)
   12008: eb a9                        	jmp	0x11fb3 <xindex::HGroup<Key, unsigned long>::put(Key const&, unsigned long const&)+0x2d3>
