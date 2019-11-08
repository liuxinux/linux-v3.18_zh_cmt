/* -*- linux-c -*- ------------------------------------------------------- *
 *
 *   Copyright (C) 1991, 1992 Linus Torvalds
 *   Copyright 2007 rPath, Inc. - All Rights Reserved
 *   Copyright 2009 Intel Corporation; author H. Peter Anvin
 *
 *   This file is part of the Linux kernel, and is made available under
 *   the terms of the GNU General Public License version 2.
 *
 * ----------------------------------------------------------------------- */

/*
 * Main module for the real-mode kernel code
 */

#include "boot.h"
#include "string.h"

struct boot_params boot_params __attribute__((aligned(16)));

char *HEAP = _end;
char *heap_end = _end;		/* Default end of heap = no heap */

/*
 * Copy the header into the boot parameter block.  Since this
 * screws up the old-style command line protocol, adjust by
 * filling in the new-style command line pointer instead.
 */

static void copy_boot_params(void)
{
	struct old_cmdline {
		u16 cl_magic;
		u16 cl_offset;
	};
	const struct old_cmdline * const oldcmd =
		(const struct old_cmdline *)OLD_CL_ADDRESS;

	BUILD_BUG_ON(sizeof boot_params != 4096);
	memcpy(&boot_params.hdr, &hdr, sizeof hdr);

	if (!boot_params.hdr.cmd_line_ptr &&
	    oldcmd->cl_magic == OLD_CL_MAGIC) {
		/* Old-style command line protocol. */
		u16 cmdline_seg;

		/* Figure out if the command line falls in the region
		   of memory that an old kernel would have copied up
		   to 0x90000... */
		if (oldcmd->cl_offset < boot_params.hdr.setup_move_size)
			cmdline_seg = ds();
		else
			cmdline_seg = 0x9000;

		boot_params.hdr.cmd_line_ptr =
			(cmdline_seg << 4) + oldcmd->cl_offset;
	}
}

/*
 * Query the keyboard lock status as given by the BIOS, and
 * set the keyboard repeat rate to maximum.  Unclear why the latter
 * is done here; this might be possible to kill off as stale code.
 */
static void keyboard_init(void)
{
	struct biosregs ireg, oreg;
	initregs(&ireg);

	ireg.ah = 0x02;		/* Get keyboard status */
	intcall(0x16, &ireg, &oreg);
	boot_params.kbd_status = oreg.al;

	ireg.ax = 0x0305;	/* Set keyboard repeat rate */
	intcall(0x16, &ireg, NULL);
}

/*
 * Get Intel SpeedStep (IST) information.
 */
static void query_ist(void)
{
	struct biosregs ireg, oreg;

	/* Some older BIOSes apparently crash on this call, so filter
	   it from machines too old to have SpeedStep at all. */
	if (cpu.level < 6)
		return;

	initregs(&ireg);
	ireg.ax  = 0xe980;	 /* IST Support */
	ireg.edx = 0x47534943;	 /* Request value */
	intcall(0x15, &ireg, &oreg);

	boot_params.ist_info.signature  = oreg.eax;
	boot_params.ist_info.command    = oreg.ebx;
	boot_params.ist_info.event      = oreg.ecx;
	boot_params.ist_info.perf_level = oreg.edx;
}

/*
 * Tell the BIOS what CPU mode we intend to run in.
 */
static void set_bios_mode(void)
{
#ifdef CONFIG_X86_64
	struct biosregs ireg;

	initregs(&ireg);
	ireg.ax = 0xec00;
	ireg.bx = 2;
	intcall(0x15, &ireg, NULL);
#endif
}

static void init_heap(void)
{
	char *stack_end;

    if (boot_params.hdr.loadflags & CAN_USE_HEAP) {
    /*检查内核设置头中的loadflags是否设置了CAN_USE_HEAP标志。*/
		asm("leal %P1(%%esp),%0"
		    : "=r" (stack_end) : "i" (-STACK_SIZE));
        /*计算栈的结束地址：stack_end = esp - STACK_SIZE
         *其中esp就是end of stack space,
         *初始化的地方在/arch/x86/boot/header.S#486*/

        /*计算堆的结束地址, heap_end_ptr的初始化是在header.S#345*/
        /*heap_end_ptr: .word _end+STACK_SIZE-512*/
        /*其中512即0x200*/
		heap_end = (char *)
			((size_t)boot_params.hdr.heap_end_ptr + 0x200);
        /*判断heap_end是否大于stack_end,如果条件成立，
         *就将stack_end设置成heap_end。*/
		if (heap_end > stack_end)
			heap_end = stack_end;
            /*堆和栈是相邻的，但是增长方向是相反的。
             *所以，他们的结束地址可以是一样的。*/
        } else {
            /* Boot protocol 2.00 only, no heap available */
            puts("WARNING: Ancient bootloader, some functionality "
                 "may be limited!\n");
        }
}

void main(void)
{
	/* First, copy the boot header into the "zeropage" */
	copy_boot_params();

	/* Initialize the early-boot console */
	console_init();
	if (cmdline_find_option_bool("debug"))
		puts("early console in setup code\n");

	/* End of heap check */
    /* 堆初始化*/
	init_heap();

	/* Make sure we have all the proper CPU support */
    /* 确认系统对CPU的支持 validate:确认 */
	if (validate_cpu()) {
		puts("Unable to boot - please use a kernel appropriate "
		     "for your CPU.\n");
		die();
	}

	/* Tell the BIOS what CPU mode we intend to run in. */
	set_bios_mode();

	/* Detect memory layout */
    /* 内存分布侦测 */
	detect_memory();

	/* Set keyboard repeat rate (why?) and query the lock flags */
    /* 键盘初始化 */
	keyboard_init();

    /*接下来内核进行一些类的参数查询*/
	/* Query MCA information */
    /* 通过#15中断来过去及其的型号信息、BIOS版本以及其他一些硬件相关的属性 */
	query_mca();

	/* Query Intel SpeedStep (IST) information */
    /* 获取Intel SpeedStep信息。
     * 首先检查CPU类型，然后调用0x15中断获得这个信息并放入boot_params中。*/
	query_ist();

	/* Query APM information */
    /* 从BIOS获得高级电源管理(APM)信息 */
#if defined(CONFIG_APM) || defined(CONFIG_APM_MODULE)
	query_apm_bios();
#endif

	/* Query EDD information */
    /* 从BIOS中查询EDD(Enhanced Disk Drive)信息。 */
#if defined(CONFIG_EDD) || defined(CONFIG_EDD_MODULE)
	query_edd();
#endif

	/* Set the video mode */
    /* 设置显示模式 */
	set_video();

	/* Do the last things and invoke protected mode */
    /* 在跳转到保护模式前做最后的准备工作 */
    /* 函数定义在arch/x86/boot/pmjump.S */
	go_to_protected_mode();
}
