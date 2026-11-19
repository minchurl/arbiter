
/home/shin/arbiter/build/companion-placement/bucket/binary:     file format elf64-x86-64


Disassembly of section .init:

Disassembly of section .plt:

Disassembly of section .plt.got:

Disassembly of section .text:

0000000000003720 <_Z6workerRN9libcuckoo14cuckoohash_mapImmSt4hashImESt8equal_toImESaISt4pairIKmmEELm4EEERK7OptionsjR6ResultRSt6atomicIjERSG_IbE>:
    3720:	push   %rbp
    3721:	push   %r15
    3723:	push   %r14
    3725:	push   %r13
    3727:	push   %r12
    3729:	push   %rbx
    372a:	sub    $0x88,%rsp
    3731:	mov    %rsi,0x18(%rsp)
    3736:	mov    0x28(%rsi),%r14
    373a:	lock incl (%r8)
    373e:	mov    %rcx,%r15
    3741:	mov    %rdi,%r13
    3744:	mov    %edx,%r12d
    3747:	movzbl (%r9),%eax
    374b:	test   $0x1,%al
    374d:	jne    376c <_Z6workerRN9libcuckoo14cuckoohash_mapImmSt4hashImESt8equal_toImESaISt4pairIKmmEELm4EEERK7OptionsjR6ResultRSt6atomicIjERSG_IbE+0x4c>
    374f:	mov    %r9,%rbx
    3752:	data16 data16 data16 data16 cs nopw 0x0(%rax,%rax,1)
    3760:	call   3470 <sched_yield@plt>
    3765:	movzbl (%rbx),%eax
    3768:	test   $0x1,%al
    376a:	je     3760 <_Z6workerRN9libcuckoo14cuckoohash_mapImmSt4hashImESt8equal_toImESaISt4pairIKmmEELm4EEERK7OptionsjR6ResultRSt6atomicIjERSG_IbE+0x40>
    376c:	mov    0x18(%rsp),%rax
    3771:	movzbl 0x30(%rax),%ecx
    3775:	mov    0x8(%rax),%rdi
    3779:	test   %cl,%cl
    377b:	mov    %r15,0x50(%rsp)
    3780:	je     37a7 <_Z6workerRN9libcuckoo14cuckoohash_mapImmSt4hashImESt8equal_toImESaISt4pairIKmmEELm4EEERK7OptionsjR6ResultRSt6atomicIjERSG_IbE+0x87>
    3782:	mov    0x10(%rax),%rsi
    3786:	mov    %rdi,%rax
    3789:	or     %rsi,%rax
    378c:	shr    $0x20,%rax
    3790:	je     379f <_Z6workerRN9libcuckoo14cuckoohash_mapImmSt4hashImESt8equal_toImESaISt4pairIKmmEELm4EEERK7OptionsjR6ResultRSt6atomicIjERSG_IbE+0x7f>
    3792:	mov    %rdi,%rax
    3795:	xor    %edx,%edx
    3797:	div    %rsi
    379a:	mov    %rax,%rdi
    379d:	jmp    37a7 <_Z6workerRN9libcuckoo14cuckoohash_mapImmSt4hashImESt8equal_toImESaISt4pairIKmmEELm4EEERK7OptionsjR6ResultRSt6atomicIjERSG_IbE+0x87>
    379f:	mov    %edi,%eax
    37a1:	xor    %edx,%edx
    37a3:	div    %esi
    37a5:	mov    %eax,%edi
    37a7:	mov    %rdi,%rax
    37aa:	imul   %r12,%rax
    37ae:	xor    %edx,%edx
    37b0:	test   %cl,%cl
    37b2:	mov    $0x0,%ecx
    37b7:	mov    %rcx,(%rsp)
    37bb:	cmove  %rdx,%rax
    37bf:	mov    %rax,0x68(%rsp)
    37c4:	mov    0x18(%rsp),%r15
    37c9:	cmpq   $0x0,0x18(%r15)
    37ce:	mov    $0x0,%ebp
    37d3:	mov    $0x0,%eax
    37d8:	mov    %rax,0x8(%rsp)
    37dd:	mov    $0x0,%eax
    37e2:	mov    %rax,0x10(%rsp)
    37e7:	je     39c4 <_Z6workerRN9libcuckoo14cuckoohash_mapImmSt4hashImESt8equal_toImESaISt4pairIKmmEELm4EEERK7OptionsjR6ResultRSt6atomicIjERSG_IbE+0x2a4>
    37ed:	lea    0x1(%r12,%r14,1),%r12
    37f2:	xor    %eax,%eax
    37f4:	mov    %rax,0x10(%rsp)
    37f9:	xor    %eax,%eax
    37fb:	mov    %rax,0x8(%rsp)
    3800:	xor    %ebp,%ebp
    3802:	xor    %eax,%eax
    3804:	mov    %rax,(%rsp)
    3808:	xor    %r14d,%r14d
    380b:	mov    %r13,0x58(%rsp)
    3810:	mov    %rdi,0x20(%rsp)
    3815:	jmp    3867 <_Z6workerRN9libcuckoo14cuckoohash_mapImmSt4hashImESt8equal_toImESaISt4pairIKmmEELm4EEERK7OptionsjR6ResultRSt6atomicIjERSG_IbE+0x147>
    3817:	nopw   0x0(%rax,%rax,1)
    3820:	movq   $0x0,0x30(%rsp)
    3829:	mov    %r13,%rdi
    382c:	lea    0x28(%rsp),%rsi
    3831:	lea    0x30(%rsp),%rdx
    3836:	call   54a0 <_ZNK9libcuckoo14cuckoohash_mapImmSt4hashImESt8equal_toImESaISt4pairIKmmEELm4EE7find_fnImZNKS9_4findImEEbRKT_RmEUlRS6_E_EEbSE_T0_>
    383b:	xor    $0x1,%al
    383d:	mov    (%rsp),%rcx
    3841:	add    0x30(%rsp),%rcx
    3846:	mov    %rcx,(%rsp)
    384a:	incq   0x10(%rsp)
    384f:	mov    0x20(%rsp),%rdi
    3854:	movzbl %al,%eax
    3857:	add    %rax,%rbp
    385a:	inc    %r14
    385d:	cmp    0x18(%r15),%r14
    3861:	jae    39c4 <_Z6workerRN9libcuckoo14cuckoohash_mapImmSt4hashImESt8equal_toImESaISt4pairIKmmEELm4EEERK7OptionsjR6ResultRSt6atomicIjERSG_IbE+0x2a4>
    3867:	mov    %r12,%rax
    386a:	shr    $0xc,%rax
    386e:	xor    %r12,%rax
    3871:	mov    %rax,%rcx
    3874:	shl    $0x19,%rcx
    3878:	xor    %rax,%rcx
    387b:	mov    %rcx,%r12
    387e:	shr    $0x1b,%r12
    3882:	xor    %rcx,%r12
    3885:	mov    %r12,%rcx
    3888:	movabs $0x2545f4914f6cdd1d,%rax
    3892:	imul   %rax,%rcx
    3896:	mov    %rcx,%rax
    3899:	xor    %edx,%edx
    389b:	div    %rdi
    389e:	mov    %rdx,%rbx
    38a1:	add    0x68(%rsp),%rbx
    38a6:	mov    %rbx,0x28(%rsp)
    38ab:	shr    $0x20,%rcx
    38af:	imul   $0x51eb851f,%rcx,%rax
    38b6:	shr    $0x25,%rax
    38ba:	imul   $0x64,%eax,%eax
    38bd:	sub    %eax,%ecx
    38bf:	cmp    %rcx,0x20(%r15)
    38c3:	ja     3820 <_Z6workerRN9libcuckoo14cuckoohash_mapImmSt4hashImESt8equal_toImESaISt4pairIKmmEELm4EEERK7OptionsjR6ResultRSt6atomicIjERSG_IbE+0x100>
    38c9:	mov    %rbx,%rax
    38cc:	shr    $0x20,%rax
    38d0:	xor    %ebx,%eax
    38d2:	mov    %eax,%ecx
    38d4:	shr    $0x10,%ecx
    38d7:	xor    %eax,%ecx
    38d9:	mov    %ecx,%eax
    38db:	shr    $0x8,%eax
    38de:	xor    %ecx,%eax
    38e0:	movzbl %al,%r15d
    38e4:	mov    %r15,0x60(%rsp)
    38e9:	movabs $0x46a4a7935bd1e995,%rax
    38f3:	imul   %rax,%r15
    38f7:	add    %rax,%r15
    38fa:	mov    0x58(%rsp),%r13
    38ff:	mov    0x38(%r13),%rdx
    3903:	mov    0x10(%r13),%rax
    3907:	bzhi   %rax,%rbx,%rcx
    390c:	mov    %rcx,%rsi
    390f:	xor    %r15,%rsi
    3912:	bzhi   %rax,%rsi,%r8
    3917:	lea    0x30(%rsp),%rdi
    391c:	mov    %r13,%rsi
    391f:	call   56c0 <_ZNK9libcuckoo14cuckoohash_mapImmSt4hashImESt8equal_toImESaISt4pairIKmmEELm4EE8lock_twoENS9_13ResizeCounterEmmSt17integral_constantIbLb0EE>
    3924:	jmp    3940 <_Z6workerRN9libcuckoo14cuckoohash_mapImmSt4hashImESt8equal_toImESaISt4pairIKmmEELm4EEERK7OptionsjR6ResultRSt6atomicIjERSG_IbE+0x220>
    3926:	cmp    $0x1,%edx
    3929:	jne    3a1b <_Z6workerRN9libcuckoo14cuckoohash_mapImmSt4hashImESt8equal_toImESaISt4pairIKmmEELm4EEERK7OptionsjR6ResultRSt6atomicIjERSG_IbE+0x2fb>
    392f:	mov    %rax,%rdi
    3932:	call   3120 <__cxa_begin_catch@plt>
    3937:	call   3510 <__cxa_end_catch@plt>
    393c:	jmp    38fa <_Z6workerRN9libcuckoo14cuckoohash_mapImmSt4hashImESt8equal_toImESaISt4pairIKmmEELm4EEERK7OptionsjR6ResultRSt6atomicIjERSG_IbE+0x1da>
    393e:	xchg   %ax,%ax
    3940:	mov    0x30(%rsp),%r8
    3945:	mov    0x38(%rsp),%r9
    394a:	lea    0x70(%rsp),%rdi
    394f:	mov    %r13,%rsi
    3952:	lea    0x28(%rsp),%rdx
    3957:	mov    0x60(%rsp),%rcx
    395c:	call   55e0 <_ZNK9libcuckoo14cuckoohash_mapImmSt4hashImESt8equal_toImESaISt4pairIKmmEELm4EE11cuckoo_findImEENS9_14table_positionERKT_hmm>
    3961:	cmpl   $0x0,0x80(%rsp)
    3969:	setne  %al
    396c:	mov    0x18(%rsp),%r15
    3971:	mov    0x20(%rsp),%rdi
    3976:	jne    3997 <_Z6workerRN9libcuckoo14cuckoohash_mapImmSt4hashImESt8equal_toImESaISt4pairIKmmEELm4EEERK7OptionsjR6ResultRSt6atomicIjERSG_IbE+0x277>
    3978:	mov    0x70(%rsp),%rcx
    397d:	lea    (%rcx,%rcx,8),%rcx
    3981:	shl    $0x3,%rcx
    3985:	add    0x18(%r13),%rcx
    3989:	mov    0x78(%rsp),%rdx
    398e:	shl    $0x4,%rdx
    3992:	incq   0x8(%rdx,%rcx,1)
    3997:	mov    0x48(%rsp),%rcx
    399c:	test   %rcx,%rcx
    399f:	je     39a4 <_Z6workerRN9libcuckoo14cuckoohash_mapImmSt4hashImESt8equal_toImESaISt4pairIKmmEELm4EEERK7OptionsjR6ResultRSt6atomicIjERSG_IbE+0x284>
    39a1:	movb   $0x0,(%rcx)
    39a4:	movq   $0x0,0x48(%rsp)
    39ad:	mov    0x40(%rsp),%rcx
    39b2:	test   %rcx,%rcx
    39b5:	je     39ba <_Z6workerRN9libcuckoo14cuckoohash_mapImmSt4hashImESt8equal_toImESaISt4pairIKmmEELm4EEERK7OptionsjR6ResultRSt6atomicIjERSG_IbE+0x29a>
    39b7:	movb   $0x0,(%rcx)
    39ba:	incq   0x8(%rsp)
    39bf:	jmp    3854 <_Z6workerRN9libcuckoo14cuckoohash_mapImmSt4hashImESt8equal_toImESaISt4pairIKmmEELm4EEERK7OptionsjR6ResultRSt6atomicIjERSG_IbE+0x134>
    39c4:	mov    0x50(%rsp),%rax
    39c9:	mov    0x10(%rsp),%rcx
    39ce:	mov    %rcx,(%rax)
    39d1:	mov    0x8(%rsp),%rcx
    39d6:	mov    %rcx,0x8(%rax)
    39da:	mov    %rbp,0x10(%rax)
    39de:	mov    (%rsp),%rcx
    39e2:	mov    %rcx,0x18(%rax)
    39e6:	add    $0x88,%rsp
    39ed:	pop    %rbx
    39ee:	pop    %r12
    39f0:	pop    %r13
    39f2:	pop    %r14
    39f4:	pop    %r15
    39f6:	pop    %rbp
    39f7:	ret    
    39f8:	mov    0x48(%rsp),%rcx
    39fd:	test   %rcx,%rcx
    3a00:	je     3a05 <_Z6workerRN9libcuckoo14cuckoohash_mapImmSt4hashImESt8equal_toImESaISt4pairIKmmEELm4EEERK7OptionsjR6ResultRSt6atomicIjERSG_IbE+0x2e5>
    3a02:	movb   $0x0,(%rcx)
    3a05:	movq   $0x0,0x48(%rsp)
    3a0e:	mov    0x40(%rsp),%rcx
    3a13:	test   %rcx,%rcx
    3a16:	je     3a1b <_Z6workerRN9libcuckoo14cuckoohash_mapImmSt4hashImESt8equal_toImESaISt4pairIKmmEELm4EEERK7OptionsjR6ResultRSt6atomicIjERSG_IbE+0x2fb>
    3a18:	movb   $0x0,(%rcx)
    3a1b:	mov    %rax,%rdi
    3a1e:	call   3560 <_Unwind_Resume@plt>

Disassembly of section .fini:
