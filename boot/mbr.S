;main mbr
;----------------------------------------------------------------------------------
%include "boot.inc"
SECTION MBR vstart=0x7c00
    mov ax, cs
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov fs, ax
    mov sp, 0x7c00
    mov ax, 0xb800
    mov gs, ax

; 清屏利用 Ox06 号功能，上卷全部行，贝IJ 可清屏
; -----------------------------------------------------------
; INT OxlO 功能号： Ox06 功能描述：上卷窗口
;------------------------------------------------------------
;输入：
;AH 功能号＝ Ox06 
; AL ＝上卷的行数（如果为 ，表示全部）
; BH ＝上卷行属性
; (CL, CH) ＝窗口左上角的（ ）位置
; (DL, DH) ＝窗口右下角的（X, ）位置
; 无返回值:
    mov ax, 0x600
    mov bx, 0x700
    mov cx, 0               ; 左上角: (0, 0)
    mov dx, 0x184f          ; 右下角: (80, 25)

    int 0x10

;;;;;;;  打印字符串  ;;;;;;;;;;;;;;;;;;;;;;;;;;;
    mov byte [gs:0x00],'1' 
    mov byte [gs:0x01],0xA4 ; A 表示绿色背景闪烁，4 表示前景色为红色

    mov byte [gs:0x02],' ' 
    mov byte [gs:0x03],0xA4 

    mov byte [gs:0x04],'M' 
    mov byte [gs:0x05],0xA4 
    
    mov byte [gs:0x06],'B' 
    mov byte [gs:0x07],0xA4 

    mov byte [gs:0x08],'R' 
    mov byte [gs:0x09],0xA4

;;;;;; 加载boot loader ;;;;;;;;;;;;;;;
    mov eax, LOADER_START_SECTOR    ;起始扇区LBA地址
    mov bx, LOADER_BASE_ADDR        ;写入的地址
    mov cx, 1                       ;待读入的扇区数
    call rd_disk_m_16               ; 以下读取程序的起始部分（一个扇区）

    jmp LOADER_BASE_ADDR

;----------------------------------------------------------------------------------
;功能:读取硬盘 n 个扇区
;----------------------------------------------------------------------------------
rd_disk_m_16:
    mov esi, eax    ;保存 eax
    mov di, cx      ;保存cx

;第 1 步:设置要读取的扇区数
    mov dx, 0x1f2
    mov al, cl
    out dx, al      ;读取的扇区数

    mov eax, esi    ;恢复 eax

;第 2 步:将 LBA 地址存入 0x1f3 ～ 0x1f6

    mov dx, 0x1f3   ;LBA 地址 7～0 位写入端口 0x1f3
    out dx, al

    mov cl, 8       ;LBA 地址 15～8 位写入端口 0x1f4
    shr eax, cl
    mov dx, 0x1f4
    out dx, al

    shr eax, cl     ;LBA 地址 23～16 位写入端口 0x1f5
    mov dx, 0x1f5
    out dx, al

    shr eax, cl
    and al, 0x0f
    or al, 0xe0     ; 设置 7～4 位为 1110,表示 lba 模式
    mov dx, 0x1f6
    out dx, al

 ;第 3 步:向 0x1f7 端口写入读命令,0x20
    mov dx,0x1f7
    mov al,0x20
    out dx,al

 ;第 4 步:检测硬盘状态
 .not_ready:
    nop
    in al, dx
    and al, 0x88
    cmp al, 0x08
    jnz .not_ready

;第 5 步:从 0x1f0 端口读数据
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

;;;;;; 填充字段 ;;;;;;;;;;;;;;;;;;;;;;;

    times 510-($-$$) db 0
    db 0x55, 0xaa