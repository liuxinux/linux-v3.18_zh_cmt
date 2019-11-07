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
 * Get the MCA system description table
 */

#include "boot.h"

int query_mca(void)
{
	struct biosregs ireg, oreg;
	u16 len;

    /*设置ah寄存器的值为0xc0,然后调用#15 BIOS中断。
     * 中断返回之后检测carry flag。如果被置位，说明BIOS不支持MCA。
     * 如果CF被设置为0，那么ES:BX指向系统信息表。*/
	initregs(&ireg);
	ireg.ah = 0xc0;
	intcall(0x15, &ireg, &oreg);

	if (oreg.eflags & X86_EFLAGS_CF)
		return -1;	/* No MCA present */

	set_fs(oreg.es);
	len = rdfs16(oreg.bx);

	if (len > sizeof(boot_params.sys_desc_table))
		len = sizeof(boot_params.sys_desc_table);
    /* 将es:bx指向的内存地址的内容拷贝到boot_params.sys_desc_table */
	copy_from_fs(&boot_params.sys_desc_table, oreg.bx, len);
	return 0;
}
