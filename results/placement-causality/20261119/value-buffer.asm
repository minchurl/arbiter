
build/placement-diagnosis/placements/xindex-buffer/binary:	file format elf64-x86-64

Disassembly of section .text:

000000000000b610 <xindex::AtomicVal<unsigned long>::update(unsigned long const&)>:
    b610: 41 57                        	pushq	%r15
    b612: 41 56                        	pushq	%r14
    b614: 53                           	pushq	%rbx
    b615: 48 bb ff ff ff ff ff ff ff ef	movabsq	$-0x1000000000000001, %rbx # imm = 0xEFFFFFFFFFFFFFFF
    b61f: 49 be ff ff ff ff ff ff ff 0f	movabsq	$0xfffffffffffffff, %r14 # imm = 0xFFFFFFFFFFFFFFF
    b629: 49 8d 56 01                  	leaq	0x1(%r14), %rdx
    b62d: 0f 1f 00                     	nopl	(%rax)
    b630: 4c 8b 47 08                  	movq	0x8(%rdi), %r8
    b634: 4c 89 c1                     	movq	%r8, %rcx
    b637: 48 21 d9                     	andq	%rbx, %rcx
    b63a: 49 09 d0                     	orq	%rdx, %r8
    b63d: 48 89 c8                     	movq	%rcx, %rax
    b640: f0                           	lock
    b641: 4c 0f b1 47 08               	cmpxchgq	%r8, 0x8(%rdi)
    b646: 48 39 c8                     	cmpq	%rcx, %rax
    b649: 75 e5                        	jne	0xb630 <xindex::AtomicVal<unsigned long>::update(unsigned long const&)+0x20>
    b64b: 48 8b 47 08                  	movq	0x8(%rdi), %rax
    b64f: 48 0f ba e0 3e               	btq	$0x3e, %rax
    b654: 72 3a                        	jb	0xb690 <xindex::AtomicVal<unsigned long>::update(unsigned long const&)+0x80>
    b656: 48 0f ba e0 3d               	btq	$0x3d, %rax
    b65b: 72 0a                        	jb	0xb667 <xindex::AtomicVal<unsigned long>::update(unsigned long const&)+0x57>
    b65d: 48 8b 06                     	movq	(%rsi), %rax
    b660: 48 89 07                     	movq	%rax, (%rdi)
    b663: b0 01                        	movb	$0x1, %al
    b665: eb 02                        	jmp	0xb669 <xindex::AtomicVal<unsigned long>::update(unsigned long const&)+0x59>
    b667: 31 c0                        	xorl	%eax, %eax
    b669: 0f ae f0                     	mfence
    b66c: 48 8b 4f 08                  	movq	0x8(%rdi), %rcx
    b670: 48 ff 47 08                  	incq	0x8(%rdi)
    b674: 4c 21 f1                     	andq	%r14, %rcx
    b677: 4c 23 77 08                  	andq	0x8(%rdi), %r14
    b67b: 48 ff c1                     	incq	%rcx
    b67e: 49 39 ce                     	cmpq	%rcx, %r14
    b681: 75 27                        	jne	0xb6aa <xindex::AtomicVal<unsigned long>::update(unsigned long const&)+0x9a>
    b683: 0f ae f0                     	mfence
    b686: 48 21 5f 08                  	andq	%rbx, 0x8(%rdi)
    b68a: 5b                           	popq	%rbx
    b68b: 41 5e                        	popq	%r14
    b68d: 41 5f                        	popq	%r15
    b68f: c3                           	retq
    b690: 48 0f ba e0 3d               	btq	$0x3d, %rax
    b695: 72 32                        	jb	0xb6c9 <xindex::AtomicVal<unsigned long>::update(unsigned long const&)+0xb9>
    b697: 48 8b 07                     	movq	(%rdi), %rax
    b69a: 49 89 ff                     	movq	%rdi, %r15
    b69d: 48 89 c7                     	movq	%rax, %rdi
    b6a0: e8 6b ff ff ff               	callq	0xb610 <xindex::AtomicVal<unsigned long>::update(unsigned long const&)>
    b6a5: 4c 89 ff                     	movq	%r15, %rdi
    b6a8: eb bf                        	jmp	0xb669 <xindex::AtomicVal<unsigned long>::update(unsigned long const&)+0x59>
    b6aa: 48 8d 3d 2f a3 00 00         	leaq	0xa32f(%rip), %rdi      # 0x159e0 <_IO_stdin_used+0x9e0>
    b6b1: 48 8d 35 98 a2 00 00         	leaq	0xa298(%rip), %rsi      # 0x15950 <_IO_stdin_used+0x950>
    b6b8: 48 8d 0d 44 a3 00 00         	leaq	0xa344(%rip), %rcx      # 0x15a03 <_IO_stdin_used+0xa03>
    b6bf: ba ad 00 00 00               	movl	$0xad, %edx
    b6c4: e8 d7 79 ff ff               	callq	0x30a0 <__assert_fail@plt>
    b6c9: 48 8d 3d 6f a2 00 00         	leaq	0xa26f(%rip), %rdi      # 0x1593f <_IO_stdin_used+0x93f>
    b6d0: 48 8d 35 79 a2 00 00         	leaq	0xa279(%rip), %rsi      # 0x15950 <_IO_stdin_used+0x950>
    b6d7: 48 8d 0d ad a2 00 00         	leaq	0xa2ad(%rip), %rcx      # 0x1598b <_IO_stdin_used+0x98b>
    b6de: ba da 00 00 00               	movl	$0xda, %edx
    b6e3: e8 b8 79 ff ff               	callq	0x30a0 <__assert_fail@plt>
