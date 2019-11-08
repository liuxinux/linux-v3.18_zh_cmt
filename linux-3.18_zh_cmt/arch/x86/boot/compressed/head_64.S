/*
 *  linux/boot/head.S
 *
 *  Copyright (C) 1991, 1992, 1993  Linus Torvalds
 */

/*
 *  head.S contains the 32-bit startup code.
 *
 * NOTE!!! Startup happens at absolute address 0x00001000, which is also where
 * the page directory will exist. The startup code will be overwritten by
 * the page directory. [According to comments etc elsewhere on a compressed
 * kernel it will end up at 0x1000 + 1Mb I hope so as I assume this. - AC]
 *
 * Page 0 is deliberately kept safe, since System Management Mode code in 
 * laptops may need to access the BIOS data stored there.  This is also
 * useful for future device drivers that either access the BIOS via VM86 
 * mode.
 */

/*
 * High loaded stuff by Hans Lermen & Werner Almesberger, Feb. 1996
 */
	.code32
	.text

#include <linux/init.h>
#include <linux/linkage.h>
#include <asm/segment.h>
#include <asm/boot.h>
#include <asm/msr.h>
#include <asm/processor-flags.h>
#include <asm/asm-offsets.h>

    /* __HEAD定义在include/linux/init.h */
    /* #define __HEAD       .section    ".head.text","ax" */
    /* 其拥有.head.text的命名和ax标记。表示这个段是可执行的也可说是包含了代码 */
	__HEAD
	.code32
ENTRY(startup_32)
	/*
	 * 32bit entry is 0 and it is ABI so immutable!
	 * If we come here directly from a bootloader,
	 * kernel(text+data+bss+brk) ramdisk, zero_page, command line
	 * all need to be under the 4G limit.
	 */
	cld//将标志寄存器的DF(方向标志)位清空。当方向标志被清空，所有的串操作指令
       //像stos、scas等等将会增加索引寄存器esi或者edi的值。
       //这里清空方向标志是因为接下来我们会使用汇编的串操作指令来做为页表腾出空间等工作。
	/*
	 * Test KEEP_SEGMENTS flag to see if the bootloader is asking
	 * us to not reload segments
	 */
    /* 从内核加载头中的loadflags字段来检查KEEP_SEGMENTS标志。 */
	testb $(1<<6), BP_loadflags(%esi)
	jnz 1f   //如果设置了KEEP_SEGMENTS,直接跳转到1处。

    /* 如果没有设置KEEP_SEGMENTS，就用__BOOT_DS更新段寄存器 */
	cli
	movl	$(__BOOT_DS), %eax
	movl	%eax, %ds
	movl	%eax, %es
	movl	%eax, %ss
1:

/*
 * Calculate the delta between where we were compiled to run
 * at and where we were actually loaded at.  This can only be done
 * with a short local call on x86.  Nothing  else will tell us what
 * address we are running at.  The reserved chunk of the real-mode
 * data at 0x1e4 (defined as a scratch field) are used as the stack
 * for this calculation. Only 4 bytes are needed.
 */
	leal	(BP_scratch+4)(%esi), %esp  /*我们把scratch的地址加上4存入esp寄存器*/
	call	1f              /*跳转1f标签*/
1:	popl	%ebp            /*并把该标签的地址放入ebq寄存器*/
	subl	$1b, %ebp       /*计算startup_32的地址（0x100000）*/

/* setup a stack and make sure cpu supports long mode. */
/* boots_stack_end标签被定义本文件中.bss*/
	movl	$boot_stack_end, %eax   /*把boots_stack_end放到eax寄存器中*/
                                    /*那么eax寄存器将包含boot_stack_end链接后的地址或者
                                     0x0+boot_stack_end*/
	addl	%ebp, %eax              /*加上ebq的startup_32实际地址就得到了boot_stack_end的实际地址*/
	movl	%eax, %esp              /*将boot_stack_end加到栈指针上*/

    /*建立了栈之后，下一步是CPU的确认*/
	call	verify_cpu      /*检查CPU是否支持长模式和SSE*/
                            /*verify_cpu定义在arch/x86/kernel/verify_cpu.S中*/
	testl	%eax, %eax      /*eax寄存器返回0表示成功，1表示失败 */
	jnz	no_longmode         /*如果eax的值不是0，就跳转到no_longmode

/*
 * Compute the delta between where we were compiled to run at
 * and where the code will actually run at.
 *
 * %ebp contains the address we are loaded at by the boot loader and %ebx
 * contains the address where we should move the kernel image temporarily
 * for safe in-place decompression.
 */

/*
 * 接下来是计算重定位地址
 */
#ifdef CONFIG_RELOCATABLE
	movl	%ebp, %ebx #ebq寄存器中的值就是startup_32标签的物理地址。这里把该值放入到ebx寄存器。
	movl	BP_kernel_alignment(%esi), %eax
	decl	%eax
	addl	%eax, %ebx
	notl	%eax
	andl	%eax, %ebx #对齐2M的整数倍
	cmpl	$LOAD_PHYSICAL_ADDR, %ebx
	jge	1f
#endif
	movl	$LOAD_PHYSICAL_ADDR, %ebx
1:

	/* Target address to relocate to for decompression */
    /* ebx寄存器中存放的是内核解压缩的目标地址。 */
	addl	$z_extract_offset, %ebx

/*
 * Prepare for entering 64 bit mode
 */
/*
 * 进入长模式（64位模式）前的准备工作
 */
	/* Load new GDT with the 64bit segments using 32bit descriptor */
    /* 使用32位描述符用64位段加载新GDT */
    /* 更新全局描述符表 */
    leal	gdt(%ebp), %eax     /*把ebq寄存器加上gdt的偏移存到eax寄存器*/
	movl	%eax, gdt+2(%ebp)   /*把eax寄存器中的地址加上gdt+2 偏移的位置*/
	lgdt	gdt(%ebp)           /*用lgdt指令载入全局描述符 */

	/* Enable PAE mode */
    /* 启用PAE模式 */
	movl	%cr4, %eax          /*将cr4寄存器的值传入eax寄存器*/
	orl	$X86_CR4_PAE, %eax      /*将第五位置1*/
	movl	%eax, %cr4          /*再写回cr4*/

 /*
  * Build early 4G boot pagetable
  */
 /*
  * 创建早期4G启动页表
  */
	/* Initialize Page tables to 0 */
    /* 初始化页表为0 */
    /* 通常需要建立6个页表，每个表都是4096字节，所以需要整理一块24K的地址空间。 */
	leal	pgtable(%ebx), %edi     /*把ebx相关的pgtable的地址放到edi寄存器*/
	xorl	%eax, %eax              /*清空eax寄存器*/
	movl	$((4096*6)/4), %ecx     /*并将ecx赋值位(4086*6)/4=6144*/
	rep	stosl                       /*把eax的值写到edi指向的地址, 然后给edi加4，ecx减4
                                     *重复知道ecx小于等于0，所有才把6144赋值给ecx*/

	/* Build Level 4 */
    /* 构建顶级页表PML4 */
	leal	pgtable + 0(%ebx), %edi /*把和ebx(startup_32)相关的pgtalbe的地址放到ebi寄存器*/
	leal	0x1007 (%edi), %eax     /*把相对edi寄存器中的地址偏移0x1007的地址放到eax寄存器*/
                                    /*0x1007是PML4的大小4096加上7.这里的7代表了PML4的项标记*/
                                    /*在这里标记是PRESENT+RW+USER*/
	movl	%eax, 0(%edi)           /*把第一个PDP（页目录指针）项的地址写到PML4*/

	/* Build Level 3 */
    /* 构建3级页表*/
	leal	pgtable + 0x1000(%ebx), %edi    /*把3级页表指针表的基地址放到edi*/
	leal	0x1007(%edi), %eax              /*把第一个2级页表目录指针表的首项的地址放到eax寄存器*/
	movl	$4, %ecx                        /*把4赋值给ecx寄存器,作为接下来循环的计数器*/
1:	movl	%eax, 0x00(%edi)                /*把第一个页目录指针项写到edi指向的地址*/
	addl	$0x00001000, %eax
	addl	$8, %edi
	decl	%ecx
	jnz	1b

	/* Build Level 2 */
    /* 构建2级列表*/
    /* 建立2048个2MB页的页表项 */
	leal	pgtable + 0x2000(%ebx), %edi
	movl	$0x00000183, %eax
	movl	$2048, %ecx
1:	movl	%eax, 0(%edi)
	addl	$0x00200000, %eax
	addl	$8, %edi
	decl	%ecx
	jnz	1b

    /* 上面映射了4G大小的内存*/
	/* Enable the boot page tables */
    /* 使能启动页表 */
	leal	pgtable(%ebx), %eax     /* 把高级页表PML4的地址放到cr3寄存器中 */
	movl	%eax, %cr3

	/* Enable Long mode in EFER (Extended Feature Enable Register) */
    /* 设置MSR中的EFER.LME标记 */
	movl	$MSR_EFER, %ecx
	rdmsr
	btsl	$_EFER_LME, %eax
	wrmsr

	/* After gdt is loaded */
	xorl	%eax, %eax
	lldt	%ax
	movl    $0x20, %eax
	ltr	%ax

	/*
	 * Setup for the jump to 64bit mode
	 *
	 * When the jump is performend we will be in long mode but
	 * in 32bit compatibility mode with EFER.LME = 1, CS.L = 0, CS.D = 1
	 * (and in turn EFER.LMA = 1).	To jump into 64bit mode we use
	 * the new gdt/idt that has __KERNEL_CS with CS.L = 1.
	 * We place all of the values on our mini stack so lret can
	 * used to perform that far jump.
	 */
	pushl	$__KERNEL_CSi                   /*把内核段代码地址入栈*/
	leal	startup_64(%ebp), %eax          /*然后将startup64的地址导入eax*/
#ifdef CONFIG_EFI_MIXED
	movl	efi32_config(%ebp), %ebx
	cmp	$0, %ebx
	jz	1f
	leal	handover_entry(%ebp), %eax
1:
#endif
	pushl	%eax                            /*把eax入栈*/

	/* Enter paged protected Mode, activating Long Mode */
    /* 通过设置cr0寄存器中的PG和PE启用分页 */
	movl	$(X86_CR0_PG | X86_CR0_PE), %eax /* Enable Paging and Protected mode */
	movl	%eax, %cr0

	/* Jump from 32bit compatibility mode into 64bit mode. */
	lret                    /*前面已经将startup_64函数的地址入栈，在lret指令之后，CPU取出了其地址跳转到那里*/
ENDPROC(startup_32)
    /*下面就到了64位模式了*/

#ifdef CONFIG_EFI_MIXED
	.org 0x190
ENTRY(efi32_stub_entry)
	add	$0x4, %esp		/* Discard return address */
	popl	%ecx
	popl	%edx
	popl	%esi

	leal	(BP_scratch+4)(%esi), %esp
	call	1f
1:	pop	%ebp
	subl	$1b, %ebp

	movl	%ecx, efi32_config(%ebp)
	movl	%edx, efi32_config+8(%ebp)
	sgdtl	efi32_boot_gdt(%ebp)

	leal	efi32_config(%ebp), %eax
	movl	%eax, efi_config(%ebp)

	jmp	startup_32
ENDPROC(efi32_stub_entry)
#endif

	.code64
	.org 0x200
ENTRY(startup_64)
	/*
	 * 64bit entry is 0x200 and it is ABI so immutable!
	 * We come here either from startup_32 or directly from a
	 * 64bit bootloader.
	 * If we come here from a bootloader, kernel(text+data+bss+brk),
	 * ramdisk, zero_page, command line could be above 4G.
	 * We depend on an identity mapped page table being provided
	 * that maps our entire kernel(text+data+bss+brk), zero page
	 * and command line.
	 */
#ifdef CONFIG_EFI_STUB
	/*
	 * The entry point for the PE/COFF executable is efi_pe_entry, so
	 * only legacy boot loaders will execute this jmp.
	 */
	jmp	preferred_addr

ENTRY(efi_pe_entry)
	movq	%rcx, efi64_config(%rip)	/* Handle */
	movq	%rdx, efi64_config+8(%rip) /* EFI System table pointer */

	leaq	efi64_config(%rip), %rax
	movq	%rax, efi_config(%rip)

	call	1f
1:	popq	%rbp
	subq	$1b, %rbp

	/*
	 * Relocate efi_config->call().
	 */
	addq	%rbp, efi64_config+88(%rip)

	movq	%rax, %rdi
	call	make_boot_params
	cmpq	$0,%rax
	je	fail
	mov	%rax, %rsi
	leaq	startup_32(%rip), %rax
	movl	%eax, BP_code32_start(%rsi)
	jmp	2f		/* Skip the relocation */

handover_entry:
	call	1f
1:	popq	%rbp
	subq	$1b, %rbp

	/*
	 * Relocate efi_config->call().
	 */
	movq	efi_config(%rip), %rax
	addq	%rbp, 88(%rax)
2:
	movq	efi_config(%rip), %rdi
	call	efi_main
	movq	%rax,%rsi
	cmpq	$0,%rax
	jne	2f
fail:
	/* EFI init failed, so hang. */
	hlt
	jmp	fail
2:
	movl	BP_code32_start(%esi), %eax
	leaq	preferred_addr(%rax), %rax
	jmp	*%rax

preferred_addr:
#endif

	/* Setup data segments. */
	xorl	%eax, %eax
	movl	%eax, %ds
	movl	%eax, %es
	movl	%eax, %ss
	movl	%eax, %fs
	movl	%eax, %gs

	/*
	 * Compute the decompressed kernel start address.  It is where
	 * we were loaded at aligned to a 2M boundary. %rbp contains the
	 * decompressed kernel start address.
	 *
	 * If it is a relocatable kernel then decompress and run the kernel
	 * from load address aligned to 2MB addr, otherwise decompress and
	 * run the kernel from LOAD_PHYSICAL_ADDR
	 *
	 * We cannot rely on the calculation done in 32-bit mode, since we
	 * may have been invoked via the 64-bit entry point.
	 */

	/* Start with the delta to where the kernel will run at. */
#ifdef CONFIG_RELOCATABLE
	leaq	startup_32(%rip) /* - $startup_32 */, %rbp
	movl	BP_kernel_alignment(%rsi), %eax
	decl	%eax
	addq	%rax, %rbp
	notq	%rax
	andq	%rax, %rbp
	cmpq	$LOAD_PHYSICAL_ADDR, %rbp
	jge	1f
#endif
	movq	$LOAD_PHYSICAL_ADDR, %rbp
1:

	/* Target address to relocate to for decompression */
	leaq	z_extract_offset(%rbp), %rbx

	/* Set up the stack */
	leaq	boot_stack_end(%rbx), %rsp

	/* Zero EFLAGS */
	pushq	$0
	popfq

/*
 * Copy the compressed kernel to the end of our buffer
 * where decompression in place becomes safe.
 */
	pushq	%rsi
	leaq	(_bss-8)(%rip), %rsi
	leaq	(_bss-8)(%rbx), %rdi
	movq	$_bss /* - $startup_32 */, %rcx
	shrq	$3, %rcx
	std
	rep	movsq
	cld
	popq	%rsi

/*
 * Jump to the relocated address.
 */
	leaq	relocated(%rbx), %rax
	jmp	*%rax

#ifdef CONFIG_EFI_STUB
	.org 0x390
ENTRY(efi64_stub_entry)
	movq	%rdi, efi64_config(%rip)	/* Handle */
	movq	%rsi, efi64_config+8(%rip) /* EFI System table pointer */

	leaq	efi64_config(%rip), %rax
	movq	%rax, efi_config(%rip)

	movq	%rdx, %rsi
	jmp	handover_entry
ENDPROC(efi64_stub_entry)
#endif

	.text
relocated:

/*
 * Clear BSS (stack is currently empty)
 */
	xorl	%eax, %eax
	leaq    _bss(%rip), %rdi
	leaq    _ebss(%rip), %rcx
	subq	%rdi, %rcx
	shrq	$3, %rcx
	rep	stosq

/*
 * Adjust our own GOT
 */
	leaq	_got(%rip), %rdx
	leaq	_egot(%rip), %rcx
1:
	cmpq	%rcx, %rdx
	jae	2f
	addq	%rbx, (%rdx)
	addq	$8, %rdx
	jmp	1b
2:
	
/*
 * Do the decompression, and jump to the new kernel..
 */
	pushq	%rsi			/* Save the real mode argument */
	movq	$z_run_size, %r9	/* size of kernel with .bss and .brk */
	pushq	%r9
	movq	%rsi, %rdi		/* real mode address */
	leaq	boot_heap(%rip), %rsi	/* malloc area for uncompression */
	leaq	input_data(%rip), %rdx  /* input_data */
	movl	$z_input_len, %ecx	/* input_len */
	movq	%rbp, %r8		/* output target address */
	movq	$z_output_len, %r9	/* decompressed length, end of relocs */
	call	decompress_kernel	/* returns kernel location in %rax */
	popq	%r9
	popq	%rsi

/*
 * Jump to the decompressed kernel.
 */
	jmp	*%rax

	.code32
no_longmode:
	/* This isn't an x86-64 CPU so hang */
1:
	hlt             /*停止CPU,期间不会发生硬件中断*/
	jmp     1b

#include "../../kernel/verify_cpu.S"

/* 在之前已经载入全局描述符表了，这里再次载入只是把CS.L=1,CS.D=0 */
/* 从而在64位模式下执行 */
	.data   /*位于.data段*/
gdt:        /*包含了5个描述符*/
	.word	gdt_end - gdt       /*.word两字节，gdt从gdt_end-gdt开始，代表gdt表的最后一个字节 */
	.long	gdt                 /*.long四字节，包含gdt的基地址 */
	.word	0
	.quad	0x0000000000000000	/* NULL descriptor null段 */
	.quad	0x00af9a000000ffff	/* __KERNEL_CS 内核代码段 */
	.quad	0x00cf92000000ffff	/* __KERNEL_DS 内核数据段*/
	.quad	0x0080890000000000	/* TS descriptor*/
	.quad   0x0000000000000000	/* TS continued */
gdt_end:

#ifdef CONFIG_EFI_STUB
efi_config:
	.quad	0

#ifdef CONFIG_EFI_MIXED
	.global efi32_config
efi32_config:
	.fill	11,8,0
	.quad	efi64_thunk
	.byte	0
#endif

	.global efi64_config
efi64_config:
	.fill	11,8,0
	.quad	efi_call
	.byte	1
#endif /* CONFIG_EFI_STUB */

/*
 * Stack and heap for uncompression
 */
	.bss
	.balign 4
boot_heap:
	.fill BOOT_HEAP_SIZE, 1, 0
boot_stack:
	.fill BOOT_STACK_SIZE, 1, 0
boot_stack_end:

/*
 * Space for page tables (not in .bss so not zeroed)
 */
/*页表空间（因为不是在.bss段，所以没有清0）*/
	.section ".pgtable","a",@nobits
	.balign 4096
pgtable:
	.fill 6*4096, 1, 0  /*大小为24KB*/
