/* ----------------------------------------------------------------------- *
 *
 *   Copyright (C) 1991, 1992 Linus Torvalds
 *   Copyright 2007 rPath, Inc. - All Rights Reserved
 *
 *   This file is part of the Linux kernel, and is made available under
 *   the terms of the GNU General Public License version 2.
 *
 * ----------------------------------------------------------------------- */

/*
 * The actual transition into protected mode
 */

#include <asm/boot.h>
#include <asm/processor-flags.h>
#include <asm/segment.h>
#include <linux/linkage.h>

	.text
	.code16

/*
 * void protected_mode_jump(u32 entrypoint, u32 bootparams);
 */
/* 第一个参数放到eax寄存器，第二个参数保存在edx寄存器 */
GLOBAL(protected_mode_jump)
	movl	%edx, %esi		# Pointer to boot_params table
                            # boot_params地址放入esi寄存器
	xorl	%ebx, %ebx      # 清除ebx
	movw	%cs, %bx        # 将cs寄存器内容放入bx寄存器
	shll	$4, %ebx        # ebx = bx<<4
	addl	%ebx, 2f        # ebx + 标号为2的代码的地址
	jmp	1f			# Short jump to serialize on 386/486
1:

	movw	$__BOOT_DS, %cx     //把数据段索引放入cx寄存器
	movw	$__BOOT_TSS, %di    //将TSS段索引放入di寄存器

    /* 通过设置CR0寄存器相应的位使CPU进入保护模式 */
	movl	%cr0, %edx
	orb	$X86_CR0_PE, %dl	# Protected mode
	movl	%edx, %cr0

    /* 在进入保护模式之后，通过一个长跳转进入32位代码 */
	# Transition to 32-bit mode
	.byte	0x66, 0xea		# ljmpl opcode #0x66操作符前缀允许混合执行16位和32位代码
                                           #0xea 跳转指令的操作符
2:	.long	in_pm32			# offset       #跳转地址偏移
	.word	__BOOT_CS		# segment      #代码段描述符索引
ENDPROC(protected_mode_jump)
# 在执行了这个跳转命令之后，我们就在保护模式下执行代码
	.code32
	.section ".text32","ax"
GLOBAL(in_pm32)
	# Set up data segments for flat 32-bit mode
    # 重置所有的段寄存器（除了cs寄存器）
    # 在上面将$__BOOT_DS(数据段描述符索引)放入了cx寄存器。
    # 所以，下面的段寄存器指向数据段
    movl	%ecx, %ds
	movl	%ecx, %es
	movl	%ecx, %fs
	movl	%ecx, %gs
	movl	%ecx, %ss
	# The 32-bit code sets up its own stack, but this way we do have
	# a valid stack if some debugging hack wants to use it.
	addl	%ebx, %esp

	# Set up TR to make Intel VT happy
	ltr	%di

	# Clear registers to allow for future extensions to the
	# 32-bit boot protocol
    # 将所有的通用寄存器清0
	xorl	%ecx, %ecx
	xorl	%edx, %edx
	xorl	%ebx, %ebx
	xorl	%ebp, %ebp
	xorl	%edi, %edi

	# Set up LDTR to make Intel VT happy
	lldt	%cx

    # 最后使用长调转跳入32位代码
	jmpl	*%eax			# Jump to the 32-bit entrypoint
ENDPROC(in_pm32)
