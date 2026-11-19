
build/placement-diagnosis/placements/xindex-buffer/binary:	file format elf64-x86-64

Disassembly of section .text:

00000000000124f0 <xindex::AltBtreeBuffer<Key, unsigned long>::get(Key const&, unsigned long&)>:
   124f0: 41 57                        	pushq	%r15
   124f2: 41 56                        	pushq	%r14
   124f4: 41 54                        	pushq	%r12
   124f6: 53                           	pushq	%rbx
   124f7: 48 83 ec 18                  	subq	$0x18, %rsp
   124fb: 48 89 d3                     	movq	%rdx, %rbx
   124fe: 49 89 f6                     	movq	%rsi, %r14
   12501: 49 bf 00 00 00 00 00 00 00 20	movabsq	$0x2000000000000000, %r15 # imm = 0x2000000000000000
   1250b: 49 bc ff ff ff ff ff ff ff 0f	movabsq	$0xfffffffffffffff, %r12 # imm = 0xFFFFFFFFFFFFFFF
   12515: 48 8b 06                     	movq	(%rsi), %rax
   12518: 48 89 44 24 10               	movq	%rax, 0x10(%rsp)
   1251d: 48 8d 74 24 10               	leaq	0x10(%rsp), %rsi
   12522: 48 8d 54 24 08               	leaq	0x8(%rsp), %rdx
   12527: e8 f4 8f ff ff               	callq	0xb520 <xindex::AltBtreeBuffer<Key, unsigned long>::locate_leaf(Key, unsigned long&)>
   1252c: 49 8d 54 24 01               	leaq	0x1(%r12), %rdx
   12531: eb 0d                        	jmp	0x12540 <xindex::AltBtreeBuffer<Key, unsigned long>::get(Key const&, unsigned long&)+0x50>
   12533: 48 89 c8                     	movq	%rcx, %rax
   12536: 66 2e 0f 1f 84 00 00 00 00 00	nopw	%cs:(%rax,%rax)
   12540: 0f b6 48 02                  	movzbl	0x2(%rax), %ecx
   12544: 84 c9                        	testb	%cl, %cl
   12546: 74 58                        	je	0x125a0 <xindex::AltBtreeBuffer<Key, unsigned long>::get(Key const&, unsigned long&)+0xb0>
   12548: 41 89 c9                     	movl	%ecx, %r9d
   1254b: 41 d0 e9                     	shrb	%r9b
   1254e: 49 8b 36                     	movq	(%r14), %rsi
   12551: 31 ff                        	xorl	%edi, %edi
   12553: 41 89 c8                     	movl	%ecx, %r8d
   12556: 66 2e 0f 1f 84 00 00 00 00 00	nopw	%cs:(%rax,%rax)
   12560: 45 0f b6 c9                  	movzbl	%r9b, %r9d
   12564: 45 8d 51 01                  	leal	0x1(%r9), %r10d
   12568: 4a 39 74 c8 10               	cmpq	%rsi, 0x10(%rax,%r9,8)
   1256d: 44 0f b6 df                  	movzbl	%dil, %r11d
   12571: 41 0f b6 fa                  	movzbl	%r10b, %edi
   12575: 41 0f 43 fb                  	cmovael	%r11d, %edi
   12579: 45 0f b6 c0                  	movzbl	%r8b, %r8d
   1257d: 45 0f 43 c1                  	cmovael	%r9d, %r8d
   12581: 44 0f b6 d7                  	movzbl	%dil, %r10d
   12585: 45 0f b6 d8                  	movzbl	%r8b, %r11d
   12589: 47 8d 0c 1a                  	leal	(%r10,%r11), %r9d
   1258d: 41 d1 e9                     	shrl	%r9d
   12590: 45 38 d3                     	cmpb	%r10b, %r11b
   12593: 77 cb                        	ja	0x12560 <xindex::AltBtreeBuffer<Key, unsigned long>::get(Key const&, unsigned long&)+0x70>
   12595: 41 38 c9                     	cmpb	%cl, %r9b
   12598: 73 66                        	jae	0x12600 <xindex::AltBtreeBuffer<Key, unsigned long>::get(Key const&, unsigned long&)+0x110>
   1259a: eb 0c                        	jmp	0x125a8 <xindex::AltBtreeBuffer<Key, unsigned long>::get(Key const&, unsigned long&)+0xb8>
   1259c: 0f 1f 40 00                  	nopl	(%rax)
   125a0: 45 31 c9                     	xorl	%r9d, %r9d
   125a3: 41 38 c9                     	cmpb	%cl, %r9b
   125a6: 73 58                        	jae	0x12600 <xindex::AltBtreeBuffer<Key, unsigned long>::get(Key const&, unsigned long&)+0x110>
   125a8: 41 0f b6 c9                  	movzbl	%r9b, %ecx
   125ac: 48 8b 74 c8 10               	movq	0x10(%rax,%rcx,8), %rsi
   125b1: 49 3b 36                     	cmpq	(%r14), %rsi
   125b4: 75 4a                        	jne	0x12600 <xindex::AltBtreeBuffer<Key, unsigned long>::get(Key const&, unsigned long&)+0x110>
   125b6: c1 e1 04                     	shll	$0x4, %ecx
   125b9: 48 8d 7c 08 30               	leaq	0x30(%rax,%rcx), %rdi
   125be: 48 8b 77 08                  	movq	0x8(%rdi), %rsi
   125c2: 0f ae f0                     	mfence
   125c5: 48 8b 0f                     	movq	(%rdi), %rcx
   125c8: 0f ae f0                     	mfence
   125cb: 4c 8b 47 08                  	movq	0x8(%rdi), %r8
   125cf: 0f ae f0                     	mfence
   125d2: 49 85 d0                     	testq	%rdx, %r8
   125d5: 75 e7                        	jne	0x125be <xindex::AltBtreeBuffer<Key, unsigned long>::get(Key const&, unsigned long&)+0xce>
   125d7: 49 31 f0                     	xorq	%rsi, %r8
   125da: 4d 85 e0                     	testq	%r12, %r8
   125dd: 75 df                        	jne	0x125be <xindex::AltBtreeBuffer<Key, unsigned long>::get(Key const&, unsigned long&)+0xce>
   125df: 48 0f ba e6 3e               	btq	$0x3e, %rsi
   125e4: 73 2a                        	jae	0x12610 <xindex::AltBtreeBuffer<Key, unsigned long>::get(Key const&, unsigned long&)+0x120>
   125e6: 4c 85 fe                     	testq	%r15, %rsi
   125e9: 0f 85 ac 00 00 00            	jne	0x1269b <xindex::AltBtreeBuffer<Key, unsigned long>::get(Key const&, unsigned long&)+0x1ab>
   125ef: 48 89 cf                     	movq	%rcx, %rdi
   125f2: eb ca                        	jmp	0x125be <xindex::AltBtreeBuffer<Key, unsigned long>::get(Key const&, unsigned long&)+0xce>
   125f4: 66 66 66 2e 0f 1f 84 00 00 00 00 00  	nopw	%cs:(%rax,%rax)
   12600: 31 c9                        	xorl	%ecx, %ecx
   12602: eb 15                        	jmp	0x12619 <xindex::AltBtreeBuffer<Key, unsigned long>::get(Key const&, unsigned long&)+0x129>
   12604: 66 66 66 2e 0f 1f 84 00 00 00 00 00  	nopw	%cs:(%rax,%rax)
   12610: 48 89 0b                     	movq	%rcx, (%rbx)
   12613: 4c 85 fe                     	testq	%r15, %rsi
   12616: 0f 94 c1                     	sete	%cl
   12619: 0f ae f0                     	mfence
   1261c: 44 0f b6 40 01               	movzbl	0x1(%rax), %r8d
   12621: 0f ae f0                     	mfence
   12624: 48 8b 74 24 08               	movq	0x8(%rsp), %rsi
   12629: 48 8b 78 08                  	movq	0x8(%rax), %rdi
   1262d: 41 80 f8 01                  	cmpb	$0x1, %r8b
   12631: 74 05                        	je	0x12638 <xindex::AltBtreeBuffer<Key, unsigned long>::get(Key const&, unsigned long&)+0x148>
   12633: 48 39 fe                     	cmpq	%rdi, %rsi
   12636: 74 55                        	je	0x1268d <xindex::AltBtreeBuffer<Key, unsigned long>::get(Key const&, unsigned long&)+0x19d>
   12638: 48 8b 48 08                  	movq	0x8(%rax), %rcx
   1263c: 48 89 4c 24 08               	movq	%rcx, 0x8(%rsp)
   12641: 0f ae f0                     	mfence
   12644: 48 8b 48 60                  	movq	0x60(%rax), %rcx
   12648: 48 85 c9                     	testq	%rcx, %rcx
   1264b: 0f 84 ef fe ff ff            	je	0x12540 <xindex::AltBtreeBuffer<Key, unsigned long>::get(Key const&, unsigned long&)+0x50>
   12651: 48 8b 71 10                  	movq	0x10(%rcx), %rsi
   12655: 49 3b 36                     	cmpq	(%r14), %rsi
   12658: 0f 87 e2 fe ff ff            	ja	0x12540 <xindex::AltBtreeBuffer<Key, unsigned long>::get(Key const&, unsigned long&)+0x50>
   1265e: 66 90                        	nop
   12660: 48 8b 41 08                  	movq	0x8(%rcx), %rax
   12664: 48 89 44 24 08               	movq	%rax, 0x8(%rsp)
   12669: 0f ae f0                     	mfence
   1266c: 48 8b 71 60                  	movq	0x60(%rcx), %rsi
   12670: 48 85 f6                     	testq	%rsi, %rsi
   12673: 0f 84 ba fe ff ff            	je	0x12533 <xindex::AltBtreeBuffer<Key, unsigned long>::get(Key const&, unsigned long&)+0x43>
   12679: 48 8b 7e 10                  	movq	0x10(%rsi), %rdi
   1267d: 48 89 c8                     	movq	%rcx, %rax
   12680: 48 89 f1                     	movq	%rsi, %rcx
   12683: 49 3b 3e                     	cmpq	(%r14), %rdi
   12686: 76 d8                        	jbe	0x12660 <xindex::AltBtreeBuffer<Key, unsigned long>::get(Key const&, unsigned long&)+0x170>
   12688: e9 b3 fe ff ff               	jmp	0x12540 <xindex::AltBtreeBuffer<Key, unsigned long>::get(Key const&, unsigned long&)+0x50>
   1268d: 89 c8                        	movl	%ecx, %eax
   1268f: 48 83 c4 18                  	addq	$0x18, %rsp
   12693: 5b                           	popq	%rbx
   12694: 41 5c                        	popq	%r12
   12696: 41 5e                        	popq	%r14
   12698: 41 5f                        	popq	%r15
   1269a: c3                           	retq
   1269b: 48 8d 3d 9d 32 00 00         	leaq	0x329d(%rip), %rdi      # 0x1593f <_IO_stdin_used+0x93f>
   126a2: 48 8d 35 a7 32 00 00         	leaq	0x32a7(%rip), %rsi      # 0x15950 <_IO_stdin_used+0x950>
   126a9: 48 8d 0d 34 3d 00 00         	leaq	0x3d34(%rip), %rcx      # 0x163e4 <_IO_stdin_used+0x13e4>
   126b0: ba cc 00 00 00               	movl	$0xcc, %edx
   126b5: e8 e6 09 ff ff               	callq	0x30a0 <__assert_fail@plt>
