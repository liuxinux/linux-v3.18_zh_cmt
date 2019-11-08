/* -*- linux-c -*- ------------------------------------------------------- *
 *
 *   Copyright (C) 1991, 1992 Linus Torvalds
 *   Copyright 2007 rPath, Inc. - All Rights Reserved
 *
 *   This file is part of the Linux kernel, and is made available under
 *   the terms of the GNU General Public License version 2.
 *
 * ----------------------------------------------------------------------- */

/*
 * Prepare the machine for transition to protected mode.
 */

#include "boot.h"
#include <asm/segment.h>

/*
 * Invoke the realmode switch hook if present; otherwise
 * disable all interrupts.
 */
static void realmode_switch_hook(void)
{
    /* realmode_swtch指向一个16位实模式代码地址，这个16为代码将禁止NMI中断
     * 如果realmode_swtch hook存在，使用lcallw指令进行远函数调用。
     * 否则直接进入else部分进行NMI的禁止。*/
	if (boot_params.hdr.realmode_swtch) {
		asm volatile("lcallw *%0"
			     : : "m" (boot_params.hdr.realmode_swtch)
			     : "eax", "ebx", "ecx", "edx");
	} else {
		asm volatile("cli");//调用cli指令清楚中断标志IF.
		outb(0x80, 0x70); /* Disable NMI *//*通过写0x80进CMOS地址寄存器0x70*/
		io_delay();/* 短暂延时以等待I/O操作完成。 */
	}
}

/*
 * Disable all interrupts at the legacy PIC.
 */
/* 
 * PIC（Programmable Interrupt Controller）中断控制器
 * 屏蔽了从中断控制器的所有中断，和主中断控制器上除IRQ2以外的所有中断。
 * IRQ2是主中断控制器上的级联中断，所有从中断控制器的中断将通过这个级联中断报告给CPU
 * */
static void mask_all_interrupts(void)
{
	outb(0xff, 0xa1);	/* Mask all interrupts on the secondary PIC */
	io_delay();
	outb(0xfb, 0x21);	/* Mask all but cascade on the primary PIC */
	io_delay();
}

/*
 * Reset IGNNE# if asserted in the FPU.
 */
static void reset_coprocessor(void)
{
    /* 将0写入I/O端口0xF0和0xF1以复位数字协处理器 */
	outb(0, 0xf0);
	io_delay();
	outb(0, 0xf1);
	io_delay();
}

/*
 * Set up the GDT
 */

struct gdt_ptr {
	u16 len;
	u32 ptr;
} __attribute__((packed));

static void setup_gdt(void)
{
    /* 使用boot_gdt数组定义了需要引入GDTR寄存器的段描述符信息 */
    /* 在这个数组中，定义了代码、数据和TSS(Task State Segment，任务状态段)的段描述符 */
    /* 但是并没有设置任何的中断调用，所以TSS段并不会被使用到。
     * TSS段存在的唯一目的就是让处理器能够进入保护模式。*/
	/* There are machines which are known to not boot with the GDT
	   being 8-byte unaligned.  Intel recommends 16 byte alignment. */
	static const u64 boot_gdt[] __attribute__((aligned(16))) = {
		/* CS: code, read/execute, 4 GB, base 0 */
		[GDT_ENTRY_BOOT_CS] = GDT_ENTRY(0xc09b, 0, 0xfffff),
		/* DS: data, read/write, 4 GB, base 0 */
		[GDT_ENTRY_BOOT_DS] = GDT_ENTRY(0xc093, 0, 0xfffff),
		/* TSS: 32-bit tss, 104 bytes, base 4096 */
		/* We only have a TSS here to keep Intel VT happy;
		   we don't actually use it for anything. */
		[GDT_ENTRY_BOOT_TSS] = GDT_ENTRY(0x0089, 4096, 103),
	};
	/* Xen HVM incorrectly stores a pointer to the gdt_ptr, instead
	   of the gdt_ptr contents.  Thus, make it static so it will
	   stay in memory, at least long enough that we switch to the
	   proper kernel GDT. */
	static struct gdt_ptr gdt;

    /* 在定义了数组之后，代码将获取GDT的长度 */
	gdt.len = sizeof(boot_gdt)-1;
    /* 将GDT的地址放入gdt.ptr */
	gdt.ptr = (u32)&boot_gdt + (ds() << 4);//目前还在实模式，所以地址就是ds<<4+数组起始地址

    /* 通过lgdtl指令将GDT信息写入GDTR寄存器 */
	asm volatile("lgdtl %0" : : "m" (gdt));
}

/*
 * Set up the IDT
 */
static void setup_idt(void)
{
	static const struct gdt_ptr null_idt = {0, 0};
    /* 使用lidtl指令将null_idt所指向的中断描述符表引入寄存器IDT */
    /* 由于null_idt没有设定中断描述符表的长度（长度为0） */
    /* 所以这段指令执行之后，实际上没有任何中断调用被设置成功（所有中断调用都是空的） */
	asm volatile("lidtl %0" : : "m" (null_idt));
}

/*
 * Actual invocation sequence
 */
void go_to_protected_mode(void)
{
	/* Hook before leaving real mode, also disables interrupts */
    /* 如果发现realmode_seitch hook, 那么将调用它，并禁止NMI中断 */
    /* 如果没有发现，则直接禁止NMI中断 */
    /* NMI中断是一类特殊的中断，往往表示系统发生了不可恢复的错误，
     * 所以在正常运行的系统中，NMI中断是不会别禁止的，但是在进入保护模式之前，
     * 由于特殊需求，代码禁止了这类中断。*/
	realmode_switch_hook();

	/* Enable the A20 gate */
    /* 使能A20 line */
	if (enable_a20()) {
		puts("A20 gate not responding, unable to boot...\n");
		die();//如果enabled_a20函数调用失败，显示一个错误消息并借宿系统运行
	}

	/* Reset coprocessor (IGNNE#) */
    /* 复位数字协处理器 */
    reset_coprocessor();

	/* Mask all interrupts in the PIC */
    /* 屏蔽从中断控制器 */
	mask_all_interrupts();


	/* Actual transition to protected mode... */
	setup_idt();//设置中断描述符表
	setup_gdt();//设置全局描述符表
    /* 完成从实模式到保护模式的跳转 */
	protected_mode_jump(boot_params.hdr.code32_start,
			    (u32)&boot_params + (ds() << 4));
}
