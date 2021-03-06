; KEYBOARD.asm
; -- Orchid generic US keyboard driver.

KEYBOARD_DATA		equ 0x60
KEYBOARD_COMMAND	equ 0x64

ISR_keyboardHandler: ;AL = key return
	xor eax, eax

	mov dl, 1				; IRQ#1
	call PIC_sendEOI		; acknowledge the interrupt to PIC

	in al, KEYBOARD_COMMAND
	and al, 0001b
	jz .noBuffer
	in al, KEYBOARD_DATA	; read key from buffer
	;cmp al, 0
	;jle .noBuffer
	or al, al
	jz .noBuffer

	call KEYBOARD_keyboardMapping	; set al to the proper key
	; KEY IS IN AL RIGHT HERE.
	mov byte [KEYBOARD_BUFFER], al

	cmp byte [SYSTEM_CURRENT_MODE], SHELL_MODE	; Shell mode?
	jne .notShellMode
	cmp byte [KEYBOARD_DISABLE_OUTPUT], TRUE
	je .notShellMode
	call SCREEN_PrintChar	; print it or handle accordingly
	jmp .leaveCall
 .notShellMode:
 .noBuffer:
 .leaveCall:
	ret


; INPUTS:
;	BH = Command Byte
;	BL = Data byte, if applicable. If 0xFF, assuming no data byte is needed.
; CF on error.
KEYBOARD_sendSpecialCmd:
	MultiPush eax,ecx
	mov al, bh
	out KEYBOARD_DATA, al
	mov cl, 200
 	.bideTime: loop .bideTime

	in al, KEYBOARD_DATA
	cmp al, 0xFF
	je .error
	cmp al, 0x00
	je .error

 	cmp bl, 0xFF
	je .leaveCall
	mov al, bl
	out KEYBOARD_DATA, al
	jmp .leaveCall
 .error:
 	stc
 .leaveCall:
 	MultiPop ecx,eax
	ret

KEYBOARD_initialize:
	push ebx
	mov bh, 0xF0	;Get/Set current Scan Code cmd.
	mov bl, 0x01	; set scan code 2
	call KEYBOARD_sendSpecialCmd
	pop ebx
	ret


bKEYBOARDSTATUS		db 0x00		; keyboard status byte for shifts, capslock, etc.
; Bit 0 = Caps lock
; Bit 1 = SHIFT Status (1=on // 0=off)

%include "libraries/drivers/keyboard/KEYMAP.asm"
