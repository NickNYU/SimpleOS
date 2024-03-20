%include "boot.inc"

section loader vstart=LOADER_BASE_ADDR
LOADER_STACK_TOP  equ  LOADER_BASE_ADDR

; 构建GDT和Descriptor
GDT_BASE:           dd 0x00000000
                    dd 0x00000000

CODE_DESC:          dd 0x0000FFFF
                    dd DESC_CODE_HIGH4

DATA_STACK_DESC:    dd 0x0000FFFF
                    dd DESC_DATA_HIGH4

VIDEO_DESC:         dd 0x80000007
                    dd DESC_VIDEO_HIGH4

GDT_SIZE equ $ - GDT_BASE
GDT_LIMIT equ GDT_SIZE - 1

times 120 dd 0                              ; 此处预留 60 个描述符的空位

; 对应的段选择子
SELECTOR_CODE   equ (0x0001 << 3) + TI_GDT + RPL0
SELECTOR_DATA   equ (0x0002 << 3) + TI_GDT + RPL0
SELECTOR_VIDEO  equ (0x0003 << 3) + TI_GDT + RPL0

; 内存大小，单位字节，此处的内存地址是0xb00
total_memory_bytes dd 0

gdt_ptr dw GDT_LIMIT
        dd GDT_BASE

;人工对齐:total_mem_bytes4+gdt_ptr6+ards_buf244+ards_nr2，共 256 字节 （ARDS是BIOS中用于存储内存信息的结构，这里不做深究）
ards_buf times 244 db 0
ards_nr dw 0

; -------------------------------------------------------------
; 开局跳转的函数入口
; -------------------------------------------------------------
loader_start:
    xor ebx, ebx
    mov edx, 0x534d4150
    mov di, ards_buf

.e820_mem_get_loop:
    mov eax, 0x0000e820
    mov ecx, 20
    int 0x15
    
    jc .e820_mem_get_failed
    
    add di, cx
    inc word [ards_nr]
    cmp ebx, 0
    jnz .e820_mem_get_loop

    mov cx, [ards_nr]
    mov ebx, ards_buf
    xor edx, edx

.find_max_mem_area:
    mov eax, [ebx]
    add eax, [ebx + 8]
    add ebx, 20
    cmp edx, eax
    jge .next_ards
    mov edx, eax

.next_ards:
    loop .find_max_mem_area
    jmp .mem_get_ok

.e820_mem_get_failed:
    mov byte [gs:0], 'f'
    mov byte [gs:2], 'a'
    mov byte [gs:4], 'i'
    mov byte [gs:6], 'l'
    mov byte [gs:8], 'e'
    mov byte [gs:10], 'd'
    ; 内存检测失败，不再继续向下执行
    jmp $

.mem_get_ok:
    mov byte [gs:0], 's'
    mov byte [gs:2], 'u'
    mov byte [gs:4], 'c'
    mov byte [gs:6], 'c'
    mov byte [gs:8], 'e'
    mov byte [gs:10], 's'
    mov byte [gs:12], 's'
    mov [total_memory_bytes], edx

;-------------------- 准备进入保护模式 -------------------------------
    ;------------ 打开A20地址线 ------------
    in al, 0x92
    or al, 00000010B
    out 0x92, al

    ;------------ 加载gdt ------------
    lgdt [gdt_ptr]

    ;------------ cr0第0位置1 ------------
    mov eax, cr0
    or eax, 0x00000001
    mov cr0, eax

    ;------------ 刷新流水线 ------------
    jmp dword SELECTOR_CODE:p_mode_start

[bits 32]
p_mode_start:
    mov ax, SELECTOR_DATA
    mov ds, ax

    mov es, ax
    mov ss, ax

    mov esp, LOADER_STACK_TOP
    mov ax, SELECTOR_VIDEO
    mov gs, ax

    ;----------------------------------------------------------------
    ; 加载kernel
    ;----------------------------------------------------------------
    mov eax, KERNEL_START_SECTOR
    mov ebx, KERNEL_BIN_BASE_ADDR
    mov ecx, 200

    call rd_disk_m_32
    
    call setup_page                             ; 创建页目录及页表并初始化页内存位图
    
    ; ----------------------------------------------------------------
    ; 将GDT从物理地址，转换为分页后的地址
    ; 栈指针，同样转换为分页后的地址
    ; ----------------------------------------------------------------
    sgdt [gdt_ptr]                              ; 保存gdt表到原来 gdt 内存的位置
    mov ebx, [gdt_ptr + 2]                      ; 前部分是 2 字节大小的偏移量，其后是 4 字节大小 GDT 基址
    or dword [ebx + 0x18 + 4], 0xc0000000
    add dword [gdt_ptr + 2],   0xc0000000
    add esp, 0xc0000000                         ; 将栈指针同样映射到内核地址

    ;-----------------------------------------------------------------
    ; 写入CR3指定分页的页目录的内存起始地址 
    ; 打开CR0的PG位，开启分页机制
    ;-----------------------------------------------------------------
    mov eax, PAGE_DIR_TABLE_POS
    mov cr3, eax

    mov eax, cr0
    or eax, 0x80000000
    mov cr0, eax

    ; ----------------- 分页机制初始化完毕，重新加载支持分页地址后的GDT -------
    lgdt [gdt_ptr]

    jmp SELECTOR_CODE:enter_kernel

    enter_kernel:
        call kernel_init
        mov esp, 0xc009f000
        jmp KERNEL_ENTRY_POINT
    
    jmp $


; -------------------------- 创建页目录以及页表 -------------------------
setup_page:
    ; 页目录表占据4KB空间，清零之
    mov ecx, 4096
    mov esi, 0
.clear_page_dir:   
    mov byte [PAGE_DIR_TABLE_POS + esi], 0
    inc esi
    loop .clear_page_dir

; 创建页目录表(PDE)
.create_pde:
    mov eax, PAGE_DIR_TABLE_POS
    add eax, 0x1000                             ; 0x1000为4KB，加上页目录表起始地址便是第 1 个页表的地址
    mov ebx, eax                                ; 此处为 ebx 赋值，是为.create_pte 做准备，ebx 为基址

    ; -----------------------------------------------------------------
    ; 页表的 0xc0000000～0xffffffff 共计 1G 属于内核
    ;       0x0～0xbfffffff        共计 3G 属于用户进程
    ;------------------------------------------------------------------
    or eax, PG_US_U | PG_RW_W | PG_P            ; 设置页目录项属性
    mov [PAGE_DIR_TABLE_POS + 0x0],   eax       ; 设置第1个页目录项
    mov [PAGE_DIR_TABLE_POS + 0xc00], eax       ; 第768(内核空间的第一个)个页目录项，与第一个相同，这样第一个和768个都指向低端4MB空间
    sub eax, 0x1000
    mov [PAGE_DIR_TABLE_POS + 4092],  eax       ; 使最后一个目录项指向页目录表自己的地址

; 创建页表(PTE)
    mov ecx, 256                                ; 1M 低端内存 / 每页大小 4k = 256, 按顺序初始化256个页表
    mov esi, 0
    mov edx, PG_US_U | PG_RW_W | PG_P
.create_pte:
    mov [ebx + esi * 4], edx                    ; 此时的 ebx 已经在上面通过 eax 赋值为 0x101000，也就是第 1 个页表的地址
    add edx, 4096                               ; edx 是页属性，加上4096就是下一个页的地址（每个步长4K这样跳转）
    inc esi
    loop .create_pte

;------------------------ 创建内核的其它PDE ----------------------------------
    mov eax, PAGE_DIR_TABLE_POS
    add eax, 0x2000                             ; 此时 eax 为第2个页表的位置
    or eax, PG_US_U | PG_RW_W | PG_P
    mov ebx, PAGE_DIR_TABLE_POS
    mov ecx, 254                                ; 范围为第 769～1022 的所有目录项数量
    mov esi, 769
.create_kernel_pde:
    mov [ebx + esi * 4], eax
    inc esi
    add eax, 0x1000
    loop .create_kernel_pde
    ret

; 保护模式的硬盘读取函数
rd_disk_m_32:

    mov esi, eax
    mov di, cx

    mov dx, 0x1f2
    mov al, cl
    out dx, al

    mov eax, esi

    mov dx, 0x1f3
    out dx, al

    mov cl, 8
    shr eax, cl
    mov dx, 0x1f4
    out dx, al

    shr eax, cl
    mov dx, 0x1f5
    out dx, al

    shr eax, cl
    and al, 0x0f
    or al, 0xe0
    mov dx, 0x1f6
    out dx, al

    mov dx, 0x1f7
    mov al, 0x20
    out dx, al

.not_ready:
    nop
    in al, dx
    and al, 0x88
    cmp al, 0x08
    jnz .not_ready

    mov ax, di
    mov dx, 256
    mul dx
    mov cx, ax
    mov dx, 0x1f0

.go_on_read:
    in ax, dx
    mov [bx], ax
    add bx, 2
    loop .go_on_read
    ret

;----------------------------------------------------------------
; load kernel 相关代码
; 将 kernel.bin 中的 segment 拷贝到编译的地址
;----------------------------------------------------------------
kernel_init:
    xor eax, eax
    xor ebx, ebx
    xor ecx, ecx
    xor edx, edx

    mov dx, [KERNEL_BIN_BASE_ADDR + 42]         ; 偏移文件 42 字节处的属性是 e_phentsize，表示 program header 大小
    mov ebx, [KERNEL_BIN_BASE_ADDR + 28]        ; 偏移文件开始部分 28 字节的地方是 e_phoff
    add ebx, KERNEL_BIN_BASE_ADDR
    mov cx, [KERNEL_BIN_BASE_ADDR + 44]         ; 偏移文件开始部分 44 字节的地方是 e_phnum，表示有几个 program header

.each_segment:
    cmp byte [ebx], PT_NULL
    je .PTNULL                                  ; 若 p_type 等于 PT_NULL，说明此 program header 未使用

    ; 准备mem_cpy参数
    push dword [ebx + 16]
    mov eax, [ebx + 4]
    add eax, KERNEL_BIN_BASE_ADDR
    push eax
    push dword [ebx + 8]

    call mem_cpy
    add esp, 12

.PTNULL:
    add ebx, edx
    loop .each_segment
    ret

mem_cpy:
    cld
    push ebp
    mov ebp, esp
    push ecx

    mov edi, [ebp + 8]
    mov esi, [ebp + 12]
    mov ecx, [ebp + 16]
    rep movsb

    pop ecx
    pop ebp
    ret