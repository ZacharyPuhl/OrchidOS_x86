; PCI.asm
; -- Enumerate the PCI Bus and check connected devices.
; ---- MAX PCI variables: 256 Buses, 32 Devices/Bus, 8 Functions/Device.

%include "libraries/drivers/PCI/PCI_definitions.asm"


; -- Capture all devices and functions using a recursive method of scanning.
; ---- Scans the first (0-th) bus, and uses each bridge to scan others.
; ---- Each device/function entry found is put into memory from PCI_INFO.
PCI_getDevicesInfo:
	MultiPush edi,eax,ebx
	ZERO eax,ebx
	call PCI_checkAllBuses
	mov dword edi, [PCI_INFO_INDEX]
	mov dword [edi], 0xFFFFFFFF		; end of block signature.
	add edi, 4
	mov dword [PCI_INFO_INDEX], edi	; Set end ptr to true end to measure full size.

	; Store the number of entries in the PCI_INFO section.
	mov dword eax, [PCI_INFO_INDEX]
	sub eax, PCI_INFO			; Get difference between end and start (size of block)
	sub eax, 4					; Take off the DWORD signature placement.
	mov ebx, 0x00000014			; Each entry is an array of 20 bytes (5 DWORDs).
	div bl						; AX/BL --> AL = Quotient // AH = Remainder (unimportant). Should not be a remainder.

	mov byte [PCI_INFO_NUM_ENTRIES], al		;store it.
	MultiPop ebx,eax,edi
	ret


; INPUTS:
;	BL = Bus Number
;	BH = Device Number (slot)
;	CL = Function Number
;	CH = Register Number (LOWEST 2 BITS = offset --> If offset=2, use high word.)
; 	*Args are pushed as a whole DWORD, with CH (reg#) being at the least significant side
;	ARG1 = (Bus<<24|Device<<16|Func<<8|Register)
; OUTPUTS:
;	AX = WORD read from CONFIG_DATA
; -- Reads from the configuration port on the PCI bus. A return WORD of FFFFh means the device does not exist.
PCI_configReadWord:
	FunctionSetup
	MultiPush ebx,ecx,edx
	ZERO eax,ebx,ecx

	mov dword edx, [ebp+8]		;edx = pushed arg
	push edx
	;mov eax, edx				; eax = edx
	call PCI_INTERNAL_translateConfigAddr	; EAX = IDSEL signal.

	; EAX now = address to send to PCI_CONFIG_DATA
	mov dx, PCI_CONFIG_ADDRESS
	out dx, eax

	xor eax, eax
	mov dx, PCI_CONFIG_DATA
	in eax, dx		; read config space addy

	xor ecx, ecx
	pop edx			; restore original arg
	and edx, 0x000000FF	; save only dl
	mov cl, dl
	and cl, 0x02	; AND register value by 00000010b (using the bits that aren't actually the register value, but are extra 00).
	; If DL was 2, the shift will be by 16, otherwise no shift is performed. So if the register offset arg has 10b at the end,
	;  it will shift the high WORD of the 32-bit section retrieved in CONFIG_DATA into the lower WORD (basically into AX)
	shl cl, 3		; DL * 8
	shr eax, cl		; Either going to be EAX >> 16 or >> 0
	and eax, 0x0000FFFF		; get low word.

	MultiPop edx,ecx,ebx
	FunctionLeave



; INPUTS:
; 	ARG1 = PCI device address (Bus<<24|Dev<<16|Func<<8|Offset)
;	ARG2 = (DWORD value to write).
PCI_WRITE_WORD_TO_PORT:
	FunctionSetup
	pushad
	ZERO eax,ebx,ecx

	mov edx, dword [ebp+8]	; EDX = PCI device address.
	call PCI_INTERNAL_translateConfigAddr	; EAX = IDSEL

	mov dx, PCI_CONFIG_ADDRESS
	out dx, eax		; Write IDSEL to start configuration cycle.

	mov eax, dword [ebp+12] ; EAX = DWORD value to write.
	mov dx, PCI_CONFIG_DATA
	out dx, eax	; write it out.

 .leaveCall:
 	popad
 	FunctionLeave



; INPUTS:
;	EDX = (Bus|Device|Function|Offset)
; OUTPUTS:
; 	EAX = Converted for proper "chip select"
; -- Converts an input such as the above (EAX) into a proper ISDEL signal for the PCI_CONFIG_ADDRESS port.
PCI_INTERNAL_translateConfigAddr:
	MultiPush ebx,ecx,edx
	mov ch, dl					; CH = Register Number
	shr edx, 8
	mov cl, dl					; CL = Function Number
	shr edx, 8
	mov bh, dl					; BH = Device Number
	shr edx, 8
	mov bl, dl					; BL = Bus Number

	and ch, 0xFC				; ensure the last 2 bits of the lowest byte in CONFIG_DATA are 00b
	and cl, 0x07				; ensure the function is only for bits 10-8 (00000111b)
	shl bh, 3					; shift the device number value up by 3 to make room to OR with CL
	or bh, cl					; Combine to make bits 15-8 of CONFIG_DATA

	mov al, 0x80				; bits 31-24 (10000000b)
	shl eax, 8
	mov al, bl					; bits 23-16 (Bus Number)
	shl eax, 8
	mov al, bh 					; bits 15-8 (Device Number (15 to 11) | Function Number (10 to 8))
	shl eax, 8
	mov al, ch					; bits 7-0	(Register Number & 11111100b)
	; EAX is now in the proper IDSEL format.
	MultiPop edx,ecx,ebx
	ret


; INPUTS:
;	EDX = Configuration input (Bus|Device|Function|Offset)
; OUTPUTS:
;	AL = type.
; -- Puts header type byte into AL. If bit 7 is set, the device has MULTIPLE FUNCTIONS.
PCI_getHeaderType:
	FunctionSetup
	push edx

	mov dword edx, [ebp+8]		;arg1
	mov dl, 0x0E				; change offset into config block. We're getting the higher WORD from offset 0x0C. 0x0E = (0x0C|PCI_GET_HIGH_WORD)

	func(PCI_configReadWord,edx)	; AX = WORD from 0x0C. High byte is BIST, low is Header Type.
	pop edx
	FunctionLeave


; INPUTS:
;	EBX = 0x0000----, with BH = Bus# & BL = Device#
; OUTPUTS:
; 	AH
; -- Checks an entire device, tells whether or not it's multi-function, and enumerates each function if so.
; ---- CF set if no VendorID is found.
PCI_checkDevice:
	FunctionSetup
	pushad
	mov dword ebx, [ebp+8]		;arg1
	and ebx, 0x0000FFFF			; Force only BX.

	mov al, bh			; Bits 31-24 = Bus#
	shl eax, 8
	mov al, bl			; Bits 23-16 = Device#
	shl eax, 8
	xor al, al			; Bits 15-08 = Function# (0 to start) --> AH
	shl eax, 8
	xor al, al			; Bits 07-00 = Offset (0 for now to get VendorID; later, this is going to turn into header info) --> AL

	; Check for a valid VendorID.
	push dword eax
	call PCI_configReadWord
	cmp word ax, 0xFFFF	; 0xFFFF = No VendorID
	pop dword eax
	je .error

	; THIS HEADER TEST IS TO SEE IF WE'RE DEALING WITH A PCI-TO-PCI BRIDGE.
	; Get Header Type in AL. BIST in AH.
	push dword eax
	call PCI_getHeaderType		; set AL = header byte
	and al, 0x7F				; 01111111b mask. Keeps multi test out.
	cmp al, 0x01				; Is the header type a PCItoPCI?
	pop dword eax				; restore before a possible call to check for secondaryBus variables.
	jne .notBridge
	call PCI_checkPCItoPCI
 .notBridge:
	; THIS HEADER TEST IS FOR MULTI-FUNCTION DEVICES.
	; Get Header Type in AL. BIST in AH.
	push dword eax
	call PCI_getHeaderType		; set AL = header byte
	; Test header for multiple functions before restoring EAX.
	and al, PCI_HEADER_MULT_FUNC
	cmp byte al, PCI_HEADER_MULT_FUNC
	pop dword eax
	je .multipleFunctions

	;This section for single-function devices.
	xor ax, ax			; reset offset and function #s
	func(PCI_checkFunction,eax)
	jmp .leaveCall

 .multipleFunctions:	; This section for devices with multiple functions.
	xor ecx, ecx
	mov cl, 8			; max of 8 functions per device.
	xor ax, ax			; reset offset and function #s
 .nextFunc:
 	func(PCI_checkFunction,eax)
	inc ah				; check next function availability.
	push dword eax
	call PCI_configReadWord
	cmp ax, 0xFFFF		; is the vendorID for this function invalid?
	pop dword eax
	jne .nextFunc		; if not, continue.

	jmp .leaveCall

 .error:	; this field is ONLY for the first test of the device's vendorID, not for subseq tests of function #s.
	popad
	stc
	FunctionLeave
 .leaveCall:
	popad
	clc
	FunctionLeave


; INPUTS:
;	EAX = (Bus|Device|Function|Offset).
; NO OUTPUTS.
; -- Check individual functions from PCI_checkDevice. Store all shared sections of config info (first 0x10 bytes) into the PCI_INFO +the arg1 to ID which dev.
PCI_checkFunction:
	FunctionSetup
	pushad
	mov dword eax, [ebp+8]		;arg1
	xor al, al

	xor ecx, ecx
	mov cl, 4
	mov dword edi, [PCI_INFO_INDEX]
	mov dword [edi], eax
	add edi, 4
 .getInfo:
	or al, PCI_GET_HIGH_WORD	; Get high word. OR guarantees it is set.
	push dword eax
	call PCI_configReadWord
	mov word [edi+2], ax
	pop dword eax
	xor al, PCI_GET_HIGH_WORD	; Toggle it back off. Getting low DWORD now.
	push dword eax
	call PCI_configReadWord
	mov word [edi], ax
	pop dword eax
	add edi, 4					; Next DWORD.
	add al, 0x04				; Next Offset.
	loop .getInfo				; executed 3 more times.

	mov dword [PCI_INFO_INDEX], edi
	popad
	FunctionLeave


; -- Check all buses. Inspect hosts and determine how many controllers there are. Follow buses thereafter.
PCI_checkAllBuses:
	pushad
;	push dword 0x00000000	; Bus0 | Dev0 | Func0 | Offset[doesn't-matter]
;	call PCI_getHeaderType	; AL = header-type
;	add esp, 4

;	and al, PCI_HEADER_MULT_FUNC
;	cmp byte al, PCI_HEADER_MULT_FUNC
;	je .multipleHosts

	;This section for single-host controller. USE THIS FOR NOW.
	; Check bus0
	func(PCI_checkBus,0x00000000)
	jmp .leaveCall

 .multipleHosts:		; Multiple Host section.
 	func(PCI_checkBus,0x00000000)
	; Bus0, Dev0, Func(0+DH), Offset0(Vendor)
	ZERO eax,ecx,edx
	mov cl, 8
  .checkNextBus:
	push dword edx
	call PCI_configReadWord
	pop dword edx
	cmp word ax, 0xFFFF
	je .breakNextBus
	inc dh		; Checking function by function now. But this is done separately to see how many buses there are.
	loop .checkNextBus

  .breakNextBus:	; at this point DH = Bus count. 0 controls 0, 1 controls 1, ..., n controls n (up to bus 7)
	xor ecx, ecx
	mov cl, dh
	dec cl			; VV - starting at Bus1
	xor edx, edx
	inc dl			; start at Bus1
 .parseNextBus:
;	cmp byte [PCI_NEXT_BUS], 0x00	; Are we waiting on a PCI-to-PCI secondary to parse?
;	je .noBridge
;	push edx
;	xor edx, edx
;	mov byte dl, [PCI_NEXT_BUS]
;	mov byte [PCI_NEXT_BUS], 0x00	; reset in case this coming bus check also has a bridge in it.
;	push dword edx
;	call PCI_checkBus	; check the secondary bus now.
;	add esp, 4
;	pop edx
;	jmp .parseNextBus	; go check again.
;  .noBridge:
	func(PCI_checkBus,edx)
	inc dl
	loop .parseNextBus
	jmp .leaveCall

 .leaveCall:
	popad
	ret


; INPUTS:
;	EAX = Bus to check. Value is in AL.
; NO OUTPUTS.
; -- Check a specific bus' devices.
PCI_checkBus:
	FunctionSetup
	MultiPush edx,ecx,ebx
	xor ecx, ecx	; device counter
	xor edx, edx	; Bus number to check
	mov dword edx, [ebp+8]	; DL = Bus#
	and edx, 0x000000FF
	shl edx, 8		; DH = DL
	xor dl, dl		; guarantee a start on Dev0

	mov cl, 32
	xor bl, bl
 .getDeviceInfo:
	push dword edx
	call PCI_checkDevice
	pop dword edx

	inc bl
	mov dl, bl		; combine DH & BL into DX
	loop .getDeviceInfo
	; bleed

 .leaveCall:
	MultiPop ebx,ecx,edx
	FunctionLeave


; INPUTS: (not stack-based)
;	EAX = (Bus|Device|Function|Offset). Func & Offset are always 0x00.
; -- Check if the current device is a PCI-to-PCI Bridge. If so, find the bus it points to and put it in the PCI_NEXT_BUS slot to check.
PCI_checkPCItoPCI:
	push eax
	call PCI_get2ndPrimBuses
	;mov byte [PCI_NEXT_BUS], ah	; AH = secondary bus.
	shr eax, 8		; AL = Bus to check.
	func(PCI_checkBus,eax)
	pop eax
	ret


; INPUTS: (not stack-based)
; 	EAX = (Bus|Device|Function|Offset).
; OUTPUTS:
; 	EAX = 0x0000----. AH = Secondary Bus# // AL = Primary Bus#
; -- Reads configs with header-type 01h only to get Secondary and Primary buses for PCI-to-PCI.
PCI_get2ndPrimBuses:
	mov al, PCI_SECONDARY_BUS	;replace offset by 0x18, low WORD, so the return gives us bus info.
	func(PCI_configReadWord,eax)
	ret


NUM_MATCHABLE_DEVICES		equ 0x08
PCI_MATCHED_DEVICE1			dd 0x00000000
PCI_MATCHED_DEVICE2			dd 0x00000000
PCI_MATCHED_DEVICE3			dd 0x00000000
PCI_MATCHED_DEVICE4			dd 0x00000000
PCI_MATCHED_DEVICE5			dd 0x00000000
PCI_MATCHED_DEVICE6			dd 0x00000000
PCI_MATCHED_DEVICE7			dd 0x00000000
PCI_MATCHED_DEVICE8			dd 0x00000000
PCI_NUM_MATCHED_DEVICES		db 0x00
; INPUTS:
;	ARG1 = (CLASS<<24|SUBCLASS<<16|INTERFACE<<8|REVISION)
; OUTPUTS:
;	No direct outputs. Stores matching devices in PCI_MATCHED_DEVICE[N], where N = the number of matching devices found.
; -- Enumerate the stored PCI devices starting @PCI_INFO
PCI_returnMatchingDevices:
	FunctionSetup
	MultiPush edi,esi,eax,ebx,ecx
	ZERO eax,ebx,ecx

	mov dword eax, [ebp+8]	;arg1 --> EAX = specific device to search for.
	and eax, 0xFFFFFF00		; mask revision number -- useless to track.
	mov esi, PCI_INFO
	mov edi, PCI_MATCHED_DEVICE1
	; Structure of PCI_INFO entries = 5DWORDs.
	;  #1 = [esi]    = Bus<<24|Dev<<16|Func<<8|00
	;  #2 = [esi+4]  = DeviceID<<16 | VendorID
	;  #3 = [esi+8]  = Status<<16|Command
	;  #4 = [esi+12] = CLASS<<24|SUBCLASS<<16|INTERFACE<<8|REVISION (or 00)
	;  #5 = [esi+16] = BIST<<24|Header<<16|Latency<<8|Cache

 .enumerateArray:
	mov dword ebx, [esi+12]
	and ebx, 0xFFFFFF00		; Mask the revision number, we don't care about it.
	cmp dword eax, ebx
	jne .noMatch
	cmp byte cl, NUM_MATCHABLE_DEVICES	; are we about to overflow?
	jae .noMatch						;  if so, protect the system.
	movsd			; [ESI] --> DWORD --> [EDI]
	sub esi, 4		; next PCI_MATCHED_DEVICE is already loaded (edi+4) thanks to movsd. just correct ESI.
	inc cl
  .noMatch:
 	add esi, 5*4	; inc EDI up by 5 DWORDs (one entry)
	cmp dword [esi], 0xFFFFFFFF		; did the index hit the signature DWORD?
	jne .enumerateArray				; nope, keep checking
	jmp .leaveCall					;  yes, exit.

 .leaveCall:
 	mov byte [PCI_NUM_MATCHED_DEVICES], cl
	MultiPop ecx,ebx,eax,esi,edi
	FunctionLeave


; Used to clean the buffers after a usage of the MATCHED_DEVICE variables.
;  Typically only called from the init.asm file.
PCI_INTERNAL_cleanMatchedBuffers:
	MultiPush edi,eax,ecx
	ZERO eax,ecx
	mov cl, NUM_MATCHABLE_DEVICES
	mov edi, PCI_MATCHED_DEVICE1
	rep stosd
	MultiPop ecx,eax,edi
	ret

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; PCI EDIT VALS FUNCTIONS;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

; INPUTS:
;	ARG1: EDX = (Bus|Device|Func|Offset). Offset is important, signals the section of the config area we're changing.
; NO OUTPUTS.
PCI_changeValue:
	FunctionSetup
	pushad
	mov dword edx, [ebp+8]		;arg1

	popad
	FunctionLeave


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; Configuration & BAR operations.

; INPUTS:
;	ARG1 = (Bus<<24|Device<<16|Func<<8|BAR#) -> Bar# = 0 to 5
; OUTPUTS:
;	EAX = Address
;	EBX => BL = Access Type (MMIO = 0, IO = 1).
PCI_BAR_getAddressesAndType_header00:
	FunctionSetup
	push ecx
	mov ebx, dword [ebp+8]	;EBX = arg1
	add bl, 0x10	; add the starting offset of BARs into a 00h header PCI table.
	or bl, 2		; get the high word of the BAR register.

	push ebx
	call PCI_configReadWord	; ax = High word
	pop ebx		; restore the arg1
	shl eax, 16		; put high word up top.
	mov ecx, eax	; copy into ecx
	xor eax, eax	; now clear eax
	xor bl, 0x02	; clear bit 1 (not bit 0) to get the low word
	push ebx
	call PCI_configReadWord	; ax = Low word
	pop ebx ;add esp, 4
	or eax, ecx		; combine the values. EAX should now contain the specified BAR from the PCI information table.

	xor ebx, ebx	; clear EBX
	push eax
	and eax, 1	; check bit0
	or eax, eax
	jz .MemMapped	; if bit0 is not set, it's a mem=mapped addr so keep EBX 0
	;bleed if EAX!=0
 .IOaddress:
 	mov ebx, 0x00000001		; EBX = I/O addr access type
	pop eax
	and eax, 0xFFFFFFFC		; Keep all bits but the lowest 2 (EAX = 4-byte-aligned I/O address)
	jmp .leaveCall
 .MemMapped:
 	pop eax
	; save state and ckeck mem-mapped addr type.
	; 0 = 32-bit, 1 = 16-bit, 2 = 64-bit
	push eax
	and eax, 0x00000006	; keep only bits 2&1
	cmp al, 0x01
	je .bits16
	cmp al, 0x02
	je .bits64
	;bleed if neither
 .bits32: ; default option
	pop eax
	and eax, 0xFFFFFFF0	; Get final 16-byte-aligned 32-bit address.
	jmp .leaveCall
 .bits64:
 	pop eax
	xor eax, eax	; 64-bit addresses unsupported. EAX = 0
	jmp .leaveCall
 .bits16:
 	pop eax
	and eax, 0x0000FFF0	; Get final 16-byte-aligned 16-bit address.
	; bleed
 .leaveCall:
 	pop ecx
	FunctionLeave


; INPUTS:
;	EAX = (Bus|Device|Function|BAR register).
PCI_BAR_getSpaceNeeded:

	ret
