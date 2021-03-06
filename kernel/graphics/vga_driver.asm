%include "Morgenroetev1.inc"

;Define VGA_DRIVER to not define GraphicDriverInterface at the same time as extern and as global
%define VGA_DRIVER

;Inlcude vga_driver overwriting the file macro
INCLUDE "graphics/vga_driver.inc"


;Holds the physical information about which graphic driver is loaded at the moment
global GraphicDriverInterface
GraphicDriverInterface:
	times (IGraphicDriver_size/8) dq DummyFunction


;Every function defined in IGraphicDriver points to this DummyFunction first
DummyFunction:
	mov rax, 0x123456
	mov rbx, 0x7FDAA
	jmp $



;bl =  read plane
%macro setReadPlane 1
	outportb VGA_GC_INDEX, 4
	outportb VGA_GC_DATA, %1
%endmacro

;bl = plane(s)
%macro setWritePlanes 1
	outportb VGA_SEQ_INDEX, 2
	outportb VGA_SEQ_DATA, %1
%endmacro


%macro outportb 2
	%if %1 > 0xFF
		mov dx, %1
		mov al, %2
		out dx, al
	%else
		mov al, %2
		out %1, al
	%endif
%endmacro

%macro inportb 1
	%if %1 > 0xFF
		mov dx, %1
		in al, dx
	%else
		in al, %1
	%endif
%endmacro

%define BYTES_PER_SCANLINE 90
%define RGB18(r,g,b) ((r*0x3F/0xFF)<<16)|((g*0x3F/0xFF)<<8)|(b*0x3F/0xFF)

;cl = index, ebx = color RGB
;writes the given color in ebx to the port cl specifies in the DAC Palette
write_dac_color:
	mov dx, 0x03C8		;Prepare the DAC for the write
	mov al, cl		;Tell the dac which entry will be written to
	out dx, al

	mov ah, bl		;Load the first component of the 18-bit color, the blue component

	shr ebx, 8		;Destroy the blue component and therefore select bh = red component, bl = green component
	add dx, 1		;Select the dac data register to put the new RGB value to it
	mov al, bh		;Load the red component

	out dx, al		;Write the red component

	mov al, bl		;Load the green component
	out dx, al		;Write the green component

	mov al, ah
	out dx, al		;Write the blue component as last one
	ret

;-------------------------------------------------------
;Sets the foreground attribute of the driver, text will be drawn in that color
;-------------------------------------------------
DeclareFunction SetForegroundAttribute( new_attr )
	mov rax, Arg_new_attr					;Load the new attribute value
	and al, 0x0F						;Only 4-bit attributes are allowed
	mov byte[ vga_driver_settings.foreground_attr ], al	;Store the new foreground color
	xor al, byte[ vga_driver_settings.background_attr ]	;Calculate the xor value between background and foreground color
								;It is important to determinate the value for setting the right color planes
	mov byte[ vga_driver_settings.xored_attr ], al		;
EndFunction
;-----------------------------------------------------------------------------
;Sets the background attribute of the driver, text will drawn onto that color
;----------------------------------------------------------------------------
DeclareFunction SetBackgroundAttribute( new_attr )
	mov rax, Arg_new_attr
	and al, 0x0F						;Only 4-bit attributes are allowed
	mov byte[ vga_driver_settings.background_attr ], al
	xor al, byte[ vga_driver_settings.foreground_attr ]	;Important for selecting to which planes to write to
	mov byte[ vga_driver_settings.xored_attr ], al
EndFunction

;----------------------------------------------------------------------------------
;Draws a character with the current foreground and background color on the screen
;----------------------------------------------------------------------------------
DeclareFunction DrawCharacter( character )
	mov r11, rbx							;Save rbx, cause rbx need to be persistent over function calls
	mov rsi, Arg_character						;Load the character value for example 'A' = 65
	mov r8d, dword[ vga_driver_settings.predrawn_backgrounds ]	;Load the address of the predrawn backgrounds
	shl esi, 3							;Calculate the offset of the font belonging the character
	mov edi, dword[ vga_driver_settings.curr_write_addr ]		;Load the address to which the pixel writing goes
	movzx ebx, byte[ vga_driver_settings.background_attr ]
	mov r9d, edi							;Backup the address to which pixel will get plotted
	add esi, Font8X8BIOS						;Calculate the absolute address of the font data
	add r8d, ebx							;Calculate the absolut address of the predrawn background fitting to the current background color
	mov r10d, dword[ vga_driver_settings.chars_written ]

	mov al, byte[ r8d ]		;Load latch register with background attributes

	mov cx, 8			;This write 8x8 character means, 8 rows need to be drawn
	xor ax, ax
	.drawBackground:
		mov byte[ edi ], al			;Write current background color because ( 0 xor background_attr ) = background_attr 
		add edi, BYTES_PER_SCANLINE		;Select next line
		sub cx, 1
		jnz .drawBackground

	setWritePlanes byte[ vga_driver_settings.xored_attr ]		;Set the planes selected by xoring foreground_attr and background_attr together
									;This will ensure that the foreground color will be written every time a 1 occurs in the font data

	mov edi, r9d							;Reload edi with the address before background drawing
	mov cx, 8
	.drawForeground:
		mov al, byte[ esi ]		;Load bitmap
		mov bl, byte[ edi ]		;Load latch register
		mov byte[ edi ], al		;Will do something like this (bitmap data xor background_attr) = Character in desired color 
		add edi, BYTES_PER_SCANLINE
		add esi, 1			;Need to load next byte of the bitmap describing the character
		sub cx, 1
		jnz .drawForeground

	mov edi, r9d				; Restore edi

	add r10d, 1
	add edi, 1				;Select the next address at which will written to


	cmp r10d, BYTES_PER_SCANLINE		;Because 8 bits form 8 pixels, the bytes per scanline value is equal to the value of chars per scanline, of the maximal character count was written
						;Do a linebreak
	jnz .done

	add edi, 630				;Select next scanline at which to put the start of characters
	xor r10d, r10d				;Reset the chars_written value

	.done:
		mov dword[ vga_driver_settings.chars_written ], r10d		;Save the important informations for next call
		mov dword[ vga_driver_settings.curr_write_addr ], edi

		mov rbx, r11
		setWritePlanes 0x0F						;It is standard to have all planes selected at function return
EndFunction

;---------------------------------------------------------------------------------
;Drawing a string with the current background color and the current foreground color
;-----------------------------------------------------------------------------
DeclareFunction DrawString( str_addr )
	mov r11, rbx						;rbx must be consitent over the call, therefore save it
	mov rsi, Arg_str_addr					;
	mov r8d, dword[ vga_driver_settings.predrawn_backgrounds ]	;Load address of the predrawn backgrounds to fast blit the backgrounds
	mov edi, dword[ vga_driver_settings.curr_write_addr ]		;Load the curr write address into edi
	movzx ebx, byte[ vga_driver_settings.background_attr ]		;load the background attribute into ebx, to calculate the offset in the predrawn backgrounds
	mov r9d, edi							;Save edi in r9d
	add r8d, ebx							;Calculate the address of the background attribute in the video memory
	mov r10d, dword[ vga_driver_settings.chars_written ]		;Load the current chars written in r10d

	;Make backups off all important registers to reload it after the drawn background
	mov r12, rsi
	mov r13, rdi
	mov r14d, r10d

	mov al, byte[ r8d ]	;Load latch register with background attributes

	.DrawBackgroundOuterLoop:
		mov edi, r9d				;Load edi with the next address to write to

		mov al, byte[ rsi ]

		test al, al
		jz .drawForeground

		cmp al, CONSOLE_CHANGE_BACKGROUND_CHAR
		jz .changeBG
		
		cmp al, CONSOLE_CHANGE_FOREGROUND_CHAR
		jz .changeFG

		cmp al, CONSOLE_LINEBREAK
		jnz .contBackDraw


		
		sub r9d, r10d				;Select the current begin of the character draw line
		add r9d, 720				;Select the next character line
		xor r10d, r10d				;Reset the character draw count in the current line
		add rsi, 1
		jmp .DrawBackgroundOuterLoop

	.contBackDraw:
		add rsi, 1				;Load the address of the next character
		add r9d, 1				;Load the draw address of the next character

		mov cx, 8				;Will draw 8x8 Font therefore there are 8 passes
		xor al, al				;zero out al, because (0 xor latch register) = background color
		.DrawBackgroundInnerLoop:
			mov byte[ edi ], al		;Write background attribute
			add edi, BYTES_PER_SCANLINE	;90 = Bytes per scanline
			sub cx, 1
			jnz .DrawBackgroundInnerLoop

			add r10d, 1			;1 chars has been written, therefore increase the chars written count
			cmp r10d, BYTES_PER_SCANLINE	;1 Byte is exactly one character width in 8x8 Font, therefore if BYTES_PER_SCANLINE chars are written, there must be a linebreak
			jnz .DrawBackgroundOuterLoop

			xor r10d, r10d			;0 Bytes are written in this line
			add r9d, 630			;Calculate the next address of the first pixel, but in the next character line
			jmp .DrawBackgroundOuterLoop
	.changeBG:
		add rsi, 1
		mov r8d, dword[ vga_driver_settings.predrawn_backgrounds ]
		movzx ebx, byte[ rsi ]
		add rsi, 1
		add r8d, ebx

		mov al, byte[ r8d ]
		jmp .DrawBackgroundOuterLoop
	.changeFG:
		add rsi, 2
		jmp .DrawBackgroundOuterLoop

	.drawForeground:
		mov rsi, r12				;background drawing is finished, restore registers
		mov rdi, r13
		mov r10d, r14d
		mov r9d, edi

		setWritePlanes byte[ vga_driver_settings.xored_attr ]	;Set every plane of (foreground_color xor background_color) to draw transparent text on that setup

		.drawForegroundOuterLoop:
			mov edi, r9d
			movzx eax, byte[ rsi ]				;movzx eax, because eax will get shifted and it will cause desaster if eax is not zero at that moment

			test al, al
			jz .done

			cmp al, CONSOLE_CHANGE_BACKGROUND_CHAR
			jz .changeBGColor

			cmp al, CONSOLE_CHANGE_FOREGROUND_CHAR
			jz .changeFGColor

			cmp al, 0x0A
			jnz .contDrawFore

			sub r9d, r10d					;Select begin of the current chatacter line
			add r9d, 720					;Select the next draw line
			xor r10d, r10d					;Reset the character draw count in the current character line
			add rsi, 1
			jmp .drawForegroundOuterLoop
		.contDrawFore:
			mov r8d, Font8X8BIOS				;Load Font address
			add rsi, 1
			shl eax, 3					;Calculate character offset in Font
			add r9d, 1
			add r8d, eax					;Calculate character address absolute

			mov cx, 8
			.DrawForegroundInnerLoop:
				mov al, byte[ r8d ]			;Load bitmap attribute
				mov bl, byte[ edi ]			;Load latch register with the value currently at location edi
				mov byte[ edi ], al			;xor the latch register with the bitmap, resulting in the prefered color

				add edi, BYTES_PER_SCANLINE		;Select next line
				add r8d, 1				;Select next entry in the bitmap
				sub cx, 1
				jnz .DrawForegroundInnerLoop

				add r10d, 1				;Increase chars written by one
				cmp r10d, BYTES_PER_SCANLINE		;If the line is full of chars do linebreak, for detailed information look above
				jnz .drawForegroundOuterLoop

				xor r10d, r10d				;Reset chars written
				add r9d, 630				;initiate linebreak
				jmp .drawForegroundOuterLoop
		.changeBGColor:
			add rsi, 1
			mov al, byte[ rsi ]
			secure_call SetBackgroundAttribute( rax )
			setWritePlanes byte[ vga_driver_settings.xored_attr ]
			add rsi, 1
			jmp .drawForegroundOuterLoop

		.changeFGColor:
			add rsi, 1
			mov al, byte[ rsi ]
			secure_call SetForegroundAttribute( rax )
			setWritePlanes byte[ vga_driver_settings.xored_attr ]
			add rsi, 1
			jmp .drawForegroundOuterLoop
	.done:
		mov dword[ vga_driver_settings.chars_written ], r10d	;Save the end status of the registers
		mov dword[ vga_driver_settings.curr_write_addr ], r9d
	setWritePlanes 0x0F						;Set all planes for write
	mov rbx, r11
EndFunction

;--------------------------------------------------------------
;Load VGADriver functions into the global interface function and preparing the output stage
;-------------------------------------------------------------
DeclareFunction LoadVGADriver()
	ReserveStackSpace SaveRBX, qword
	UpdateStackPtr

	mov_ts qword[ SaveRBX ], rbx			;RBX must be consistent over calls

	;Update Polymorphic function pointers
	ResoluteFunctionName ClearScreen, 0				;Because the function name was defined by morgenroete, the name must be resoluted
	mov qword[ GraphicDriverInterface + IGraphicDriver.clearScreen ], MGR_RFuncName

	ResoluteFunctionName SetForegroundAttribute, 1
	mov qword[ GraphicDriverInterface + IGraphicDriver.set_foreground_attr ], MGR_RFuncName

	ResoluteFunctionName SetBackgroundAttribute, 1
	mov qword[ GraphicDriverInterface + IGraphicDriver.set_background_attr ], MGR_RFuncName

	ResoluteFunctionName DrawCharacter, 1
	mov qword[ GraphicDriverInterface + IGraphicDriver.draw_character ], MGR_RFuncName

	ResoluteFunctionName DrawString, 1
	mov qword[ GraphicDriverInterface + IGraphicDriver.draw_string ], MGR_RFuncName

	;Set up graphics mode 720x480 at 4 colors
	mov rdi, graphic_720x480x16
	call write_vga_regs


;Set up colors, cause the DAC is after a switch like that not always correctly initialised
;The colors defined by the DAC are 18-bits width therefore, they are defined in a table below
	mov rdi, VGA_ColorPalette
	mov si, 1

	.setUpPalette:
		mov cx, si			;cx = color index
		mov ebx, dword[ edi ]		;ebx = color in RGB 18-bit format
		call write_dac_color

		add si, 1
		add edi, 4
		cmp si, 16
		jnz .setUpPalette

	;Now draw the predrawn backgrounds for very fast screen clearing and background blitting
	mov edi, dword[ vga_driver_settings.predrawn_backgrounds ]
	xor cl, cl
	mov bx, 0xFF	;load bl with 0xFF, and bh with 0
	xor si, si	;esi is consistent over the macro calls, therefore it holds the counter

	.draw_back:
		setWritePlanes cl	;Set only the planes the color cosist of

		mov byte[ edi ], bl	;Set every plane to 1

		not cl			;Now set all planes which are not in the color

		setWritePlanes cl

		add si, 1
		mov byte[ edi ], bh	;Set plane bits to zero

		add edi, 1		;Now the background color is set up at location edi + si

		mov cx, si
		cmp cl, 16
		jnz .draw_back

	setWritePlanes 0x0F		;Select all planes for write
	outportb VGA_GC_INDEX, 3
	outportb VGA_GC_DATA, 0x18		;Select the logical operation xor for the output stage, can be used to draw fast background foreground images with only 2 IO-Port accesses
	mov_ts rbx, qword[ SaveRBX ]		;Restore rbx
EndFunction


;---------------------------------------------------
;Clears the screen with the current background color
;----------------------------------------------------
DeclareFunction ClearScreen()
	outportb VGA_GC_INDEX, 5
	outportb VGA_GC_DATA, 1		;Select vga write mode 1 ( means content of the latch register is written directly to vram )


	mov eax, dword[ vga_driver_settings.predrawn_backgrounds ]	;Load the list of predrawn backgrounds
	mov edi, dword[ vga_driver_settings.lfb_addr ]

	add al, byte[ vga_driver_settings.background_attr ]		;add the background attribute to get the right index into eax
	adc ah, 0

	mov al, byte[ eax ]	;Load the latch register

	mov ecx, 90*480		;720*480 : 8 Pixels per byte => 90*480 bytes need to be cleared
	mov eax, dword[ vga_driver_settings.lfb_addr ]
	.DrawBackground:
		mov byte[ edi ], al		;It is unneccessary what is in al, because the latch register is written to vram and nothing from the host memory
		add edi, 1
		sub ecx, 1
		jnz .DrawBackground

	mov dword[ vga_driver_settings.curr_write_addr ], eax
	mov dword[ vga_driver_settings.chars_written ], 0
	outportb VGA_GC_INDEX, 5
	outportb VGA_GC_DATA, 0		;Select standard write mode 0 at the end
EndFunction

;-----------------------------------------------
; Copying the predefined register dumps of the vga mode into the actual vga registers to set this mode
;-------------------------------------------
write_vga_regs:
	outportb VGA_MISC_WRITE, byte[ edi ]	;Write VGA Misc write
	add edi, 1

	xor cx, cx

	;Write sequenzer registers
	.loop0:
		outportb VGA_SEQ_INDEX, cl
		outportb VGA_SEQ_DATA, byte[ edi ]
		add edi, 1
		add cx, 1
		cmp cx, VGA_NUM_SEQ_REGS
		jnz .loop0

	;Unlock CRTC Registers
	outportb VGA_CRTC_INDEX, 0x03

	inportb VGA_CRTC_DATA
	or al, 0x80
	outportb VGA_CRTC_DATA, al
	outportb VGA_CRTC_INDEX, 0x11
	inportb VGA_CRTC_DATA
	and al, ~0x80
	outportb VGA_CRTC_DATA, al

	;Registers must stay unlocked
	or byte[edi+0x03], 0x80
	and byte[edi+0x11], ~0x80

	xor cx, cx

	;Write CRTC Registers
	.loop1:
		outportb VGA_CRTC_INDEX, cl
		outportb VGA_CRTC_DATA, byte[ edi ]
		add edi, 1
		add cx, 1
		cmp cx, VGA_NUM_CRTC_REGS
		jnz .loop1

	xor cx, cx

	.loop2:
		outportb VGA_GC_INDEX, cl
		outportb VGA_GC_DATA, byte[ edi ]
		add edi, 1
		add cx, 1
		cmp cx, VGA_NUM_GC_REGS
		jnz .loop2

	xor cx, cx

	.loop3:
		inportb VGA_INSTAT_READ
		outportb VGA_AC_INDEX, cl
		outportb VGA_AC_WRITE, byte[ edi ]
		add edi, 1
		add cx, 1
		cmp cx, VGA_NUM_AC_REGS
		jnz .loop3


	inportb VGA_INSTAT_READ
	outportb VGA_AC_INDEX, 0x20
	ret


ImportAllMgrFunctions

;Defines Colors starting at color 1 going up to color 0xF
VGA_ColorPalette dd RGB18(0x00,0x00,0xFF),RGB18(0x00,0xFF,0x00),RGB18(0x33,0xCC,0xFF),RGB18(0xFF,0x00,0x00),RGB18(0xCC,0x33,0xFF),RGB18(0xB8,0x5C,0x00),\
RGB18(0xA7,0xA7,0xC0),RGB18(0x53,0x53,0x7C),RGB18(0x00,0x99,0xFF),RGB18(0x33,0xFF,0x33),RGB18(0x00,0xFF,0xFF),RGB18(0xFF,0x47,0x19),0x3F253F,0x3F3F00,RGB18(0xFF,0xFF,0xFF)

vga_driver_settings:
	.foreground_attr db 0xF
	.background_attr db 0
	.xored_attr db 0xF
	.lfb_addr dq 0xA0000
	.curr_write_addr dq 0xA0000
	.phys_scr_size dq (720*480/8)
	.phys_scr_size_clr dq (720*480/64)
	.chars_written dd 0
	.predrawn_backgrounds dd 0xAA8C0

graphic_720x480x16:
	.misc db 0xE7
	.seq db 0x03, 0x01, 0x08, 0x00, 0x06
	.crtc db 0x6B, 0x59, 0x5A, 0x82, 0x60, 0x8D, 0x0B, 0x3E,0x00, 0x40, 0x06, 0x07, 0x00, 0x00, 0x00, 0x00,0xEA, 0x0C, 0xDF, 0x2D, 0x08, 0xE8, 0x05, 0xE3,0xFF
	.gc db 0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x05, 0x0F,0xFF
	.ac db 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0xE, 0xF,0x01, 0x00, 0x0F, 0x00, 0x00


Font8X8BIOS:
	db 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
	db 0x7E, 0x81, 0xA5, 0x81, 0xBD, 0x99, 0x81, 0x7E
	db 0x7E, 0xFF, 0xDB, 0xFF, 0xC3, 0xE7, 0xFF, 0x7E
	db 0x6C, 0xFE, 0xFE, 0xFE, 0x7C, 0x38, 0x10, 0x00
	db 0x10, 0x38, 0x7C, 0xFE, 0x7C, 0x38, 0x10, 0x00
	db 0x38, 0x7C, 0x38, 0xFE, 0xFE, 0x92, 0x10, 0x7C
	db 0x00, 0x10, 0x38, 0x7C, 0xFE, 0x7C, 0x38, 0x7C
	db 0x00, 0x00, 0x18, 0x3C, 0x3C, 0x18, 0x00, 0x00
	db 0xFF, 0xFF, 0xE7, 0xC3, 0xC3, 0xE7, 0xFF, 0xFF
	db 0x00, 0x3C, 0x66, 0x42, 0x42, 0x66, 0x3C, 0x00
	db 0xFF, 0xC3, 0x99, 0xBD, 0xBD, 0x99, 0xC3, 0xFF
	db 0x0F, 0x07, 0x0F, 0x7D, 0xCC, 0xCC, 0xCC, 0x78
	db 0x3C, 0x66, 0x66, 0x66, 0x3C, 0x18, 0x7E, 0x18
	db 0x3F, 0x33, 0x3F, 0x30, 0x30, 0x70, 0xF0, 0xE0
	db 0x7F, 0x63, 0x7F, 0x63, 0x63, 0x67, 0xE6, 0xC0
	db 0x99, 0x5A, 0x3C, 0xE7, 0xE7, 0x3C, 0x5A, 0x99
	db 0x80, 0xE0, 0xF8, 0xFE, 0xF8, 0xE0, 0x80, 0x00
	db 0x02, 0x0E, 0x3E, 0xFE, 0x3E, 0x0E, 0x02, 0x00
	db 0x18, 0x3C, 0x7E, 0x18, 0x18, 0x7E, 0x3C, 0x18
	db 0x66, 0x66, 0x66, 0x66, 0x66, 0x00, 0x66, 0x00
	db 0x7F, 0xDB, 0xDB, 0x7B, 0x1B, 0x1B, 0x1B, 0x00
	db 0x3E, 0x63, 0x38, 0x6C, 0x6C, 0x38, 0x86, 0xFC
	db 0x00, 0x00, 0x00, 0x00, 0x7E, 0x7E, 0x7E, 0x00
	db 0x18, 0x3C, 0x7E, 0x18, 0x7E, 0x3C, 0x18, 0xFF
	db 0x18, 0x3C, 0x7E, 0x18, 0x18, 0x18, 0x18, 0x00
	db 0x18, 0x18, 0x18, 0x18, 0x7E, 0x3C, 0x18, 0x00
	db 0x00, 0x18, 0x0C, 0xFE, 0x0C, 0x18, 0x00, 0x00
	db 0x00, 0x30, 0x60, 0xFE, 0x60, 0x30, 0x00, 0x00
	db 0x00, 0x00, 0xC0, 0xC0, 0xC0, 0xFE, 0x00, 0x00
	db 0x00, 0x24, 0x66, 0xFF, 0x66, 0x24, 0x00, 0x00
	db 0x00, 0x18, 0x3C, 0x7E, 0xFF, 0xFF, 0x00, 0x00
	db 0x00, 0xFF, 0xFF, 0x7E, 0x3C, 0x18, 0x00, 0x00
	db 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
	db 0x18, 0x3C, 0x3C, 0x18, 0x18, 0x00, 0x18, 0x00
	db 0x6C, 0x6C, 0x6C, 0x00, 0x00, 0x00, 0x00, 0x00
	db 0x6C, 0x6C, 0xFE, 0x6C, 0xFE, 0x6C, 0x6C, 0x00
	db 0x18, 0x7E, 0xC0, 0x7C, 0x06, 0xFC, 0x18, 0x00
	db 0x00, 0xC6, 0xCC, 0x18, 0x30, 0x66, 0xC6, 0x00
	db 0x38, 0x6C, 0x38, 0x76, 0xDC, 0xCC, 0x76, 0x00
	db 0x30, 0x30, 0x60, 0x00, 0x00, 0x00, 0x00, 0x00
	db 0x18, 0x30, 0x60, 0x60, 0x60, 0x30, 0x18, 0x00
	db 0x60, 0x30, 0x18, 0x18, 0x18, 0x30, 0x60, 0x00
	db 0x00, 0x66, 0x3C, 0xFF, 0x3C, 0x66, 0x00, 0x00
	db 0x00, 0x18, 0x18, 0x7E, 0x18, 0x18, 0x00, 0x00
	db 0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x18, 0x30
	db 0x00, 0x00, 0x00, 0x7E, 0x00, 0x00, 0x00, 0x00
	db 0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x18, 0x00
	db 0x06, 0x0C, 0x18, 0x30, 0x60, 0xC0, 0x80, 0x00
	db 0x7C, 0xCE, 0xDE, 0xF6, 0xE6, 0xC6, 0x7C, 0x00
	db 0x30, 0x70, 0x30, 0x30, 0x30, 0x30, 0xFC, 0x00
	db 0x78, 0xCC, 0x0C, 0x38, 0x60, 0xCC, 0xFC, 0x00
	db 0x78, 0xCC, 0x0C, 0x38, 0x0C, 0xCC, 0x78, 0x00
	db 0x1C, 0x3C, 0x6C, 0xCC, 0xFE, 0x0C, 0x1E, 0x00
	db 0xFC, 0xC0, 0xF8, 0x0C, 0x0C, 0xCC, 0x78, 0x00
	db 0x38, 0x60, 0xC0, 0xF8, 0xCC, 0xCC, 0x78, 0x00
	db 0xFC, 0xCC, 0x0C, 0x18, 0x30, 0x30, 0x30, 0x00
	db 0x78, 0xCC, 0xCC, 0x78, 0xCC, 0xCC, 0x78, 0x00
	db 0x78, 0xCC, 0xCC, 0x7C, 0x0C, 0x18, 0x70, 0x00
	db 0x00, 0x18, 0x18, 0x00, 0x00, 0x18, 0x18, 0x00
	db 0x00, 0x18, 0x18, 0x00, 0x00, 0x18, 0x18, 0x30
	db 0x18, 0x30, 0x60, 0xC0, 0x60, 0x30, 0x18, 0x00
	db 0x00, 0x00, 0x7E, 0x00, 0x7E, 0x00, 0x00, 0x00
	db 0x60, 0x30, 0x18, 0x0C, 0x18, 0x30, 0x60, 0x00
	db 0x3C, 0x66, 0x0C, 0x18, 0x18, 0x00, 0x18, 0x00
	db 0x7C, 0xC6, 0xDE, 0xDE, 0xDC, 0xC0, 0x7C, 0x00
	db 0x30, 0x78, 0xCC, 0xCC, 0xFC, 0xCC, 0xCC, 0x00
	db 0xFC, 0x66, 0x66, 0x7C, 0x66, 0x66, 0xFC, 0x00
	db 0x3C, 0x66, 0xC0, 0xC0, 0xC0, 0x66, 0x3C, 0x00
	db 0xF8, 0x6C, 0x66, 0x66, 0x66, 0x6C, 0xF8, 0x00
	db 0xFE, 0x62, 0x68, 0x78, 0x68, 0x62, 0xFE, 0x00
	db 0xFE, 0x62, 0x68, 0x78, 0x68, 0x60, 0xF0, 0x00
	db 0x3C, 0x66, 0xC0, 0xC0, 0xCE, 0x66, 0x3A, 0x00
	db 0xCC, 0xCC, 0xCC, 0xFC, 0xCC, 0xCC, 0xCC, 0x00
	db 0x78, 0x30, 0x30, 0x30, 0x30, 0x30, 0x78, 0x00
	db 0x1E, 0x0C, 0x0C, 0x0C, 0xCC, 0xCC, 0x78, 0x00
	db 0xE6, 0x66, 0x6C, 0x78, 0x6C, 0x66, 0xE6, 0x00
	db 0xF0, 0x60, 0x60, 0x60, 0x62, 0x66, 0xFE, 0x00
	db 0xC6, 0xEE, 0xFE, 0xFE, 0xD6, 0xC6, 0xC6, 0x00
	db 0xC6, 0xE6, 0xF6, 0xDE, 0xCE, 0xC6, 0xC6, 0x00
	db 0x38, 0x6C, 0xC6, 0xC6, 0xC6, 0x6C, 0x38, 0x00
	db 0xFC, 0x66, 0x66, 0x7C, 0x60, 0x60, 0xF0, 0x00
	db 0x7C, 0xC6, 0xC6, 0xC6, 0xD6, 0x7C, 0x0E, 0x00
	db 0xFC, 0x66, 0x66, 0x7C, 0x6C, 0x66, 0xE6, 0x00
	db 0x7C, 0xC6, 0xE0, 0x78, 0x0E, 0xC6, 0x7C, 0x00
	db 0xFC, 0xB4, 0x30, 0x30, 0x30, 0x30, 0x78, 0x00
	db 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xFC, 0x00
	db 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0x78, 0x30, 0x00
	db 0xC6, 0xC6, 0xC6, 0xC6, 0xD6, 0xFE, 0x6C, 0x00
	db 0xC6, 0xC6, 0x6C, 0x38, 0x6C, 0xC6, 0xC6, 0x00
	db 0xCC, 0xCC, 0xCC, 0x78, 0x30, 0x30, 0x78, 0x00
	db 0xFE, 0xC6, 0x8C, 0x18, 0x32, 0x66, 0xFE, 0x00
	db 0x78, 0x60, 0x60, 0x60, 0x60, 0x60, 0x78, 0x00
	db 0xC0, 0x60, 0x30, 0x18, 0x0C, 0x06, 0x02, 0x00
	db 0x78, 0x18, 0x18, 0x18, 0x18, 0x18, 0x78, 0x00
	db 0x10, 0x38, 0x6C, 0xC6, 0x00, 0x00, 0x00, 0x00
	db 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF
	db 0x30, 0x30, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00
	db 0x00, 0x00, 0x78, 0x0C, 0x7C, 0xCC, 0x76, 0x00
	db 0xE0, 0x60, 0x60, 0x7C, 0x66, 0x66, 0xDC, 0x00
	db 0x00, 0x00, 0x78, 0xCC, 0xC0, 0xCC, 0x78, 0x00
	db 0x1C, 0x0C, 0x0C, 0x7C, 0xCC, 0xCC, 0x76, 0x00
	db 0x00, 0x00, 0x78, 0xCC, 0xFC, 0xC0, 0x78, 0x00
	db 0x38, 0x6C, 0x64, 0xF0, 0x60, 0x60, 0xF0, 0x00
	db 0x00, 0x00, 0x76, 0xCC, 0xCC, 0x7C, 0x0C, 0xF8
	db 0xE0, 0x60, 0x6C, 0x76, 0x66, 0x66, 0xE6, 0x00
	db 0x30, 0x00, 0x70, 0x30, 0x30, 0x30, 0x78, 0x00
	db 0x0C, 0x00, 0x1C, 0x0C, 0x0C, 0xCC, 0xCC, 0x78
	db 0xE0, 0x60, 0x66, 0x6C, 0x78, 0x6C, 0xE6, 0x00
	db 0x70, 0x30, 0x30, 0x30, 0x30, 0x30, 0x78, 0x00
	db 0x00, 0x00, 0xCC, 0xFE, 0xFE, 0xD6, 0xD6, 0x00
	db 0x00, 0x00, 0xB8, 0xCC, 0xCC, 0xCC, 0xCC, 0x00
	db 0x00, 0x00, 0x78, 0xCC, 0xCC, 0xCC, 0x78, 0x00
	db 0x00, 0x00, 0xDC, 0x66, 0x66, 0x7C, 0x60, 0xF0
	db 0x00, 0x00, 0x76, 0xCC, 0xCC, 0x7C, 0x0C, 0x1E
	db 0x00, 0x00, 0xDC, 0x76, 0x62, 0x60, 0xF0, 0x00
	db 0x00, 0x00, 0x7C, 0xC0, 0x70, 0x1C, 0xF8, 0x00
	db 0x10, 0x30, 0xFC, 0x30, 0x30, 0x34, 0x18, 0x00
	db 0x00, 0x00, 0xCC, 0xCC, 0xCC, 0xCC, 0x76, 0x00
	db 0x00, 0x00, 0xCC, 0xCC, 0xCC, 0x78, 0x30, 0x00
	db 0x00, 0x00, 0xC6, 0xC6, 0xD6, 0xFE, 0x6C, 0x00
	db 0x00, 0x00, 0xC6, 0x6C, 0x38, 0x6C, 0xC6, 0x00
	db 0x00, 0x00, 0xCC, 0xCC, 0xCC, 0x7C, 0x0C, 0xF8
	db 0x00, 0x00, 0xFC, 0x98, 0x30, 0x64, 0xFC, 0x00
	db 0x1C, 0x30, 0x30, 0xE0, 0x30, 0x30, 0x1C, 0x00
	db 0x18, 0x18, 0x18, 0x00, 0x18, 0x18, 0x18, 0x00
	db 0xE0, 0x30, 0x30, 0x1C, 0x30, 0x30, 0xE0, 0x00
	db 0x76, 0xDC, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
	db 0x00, 0x10, 0x38, 0x6C, 0xC6, 0xC6, 0xFE, 0x00
	db 0x7C, 0xC6, 0xC0, 0xC6, 0x7C, 0x0C, 0x06, 0x7C
	db 0x00, 0xCC, 0x00, 0xCC, 0xCC, 0xCC, 0x76, 0x00
	db 0x1C, 0x00, 0x78, 0xCC, 0xFC, 0xC0, 0x78, 0x00
	db 0x7E, 0x81, 0x3C, 0x06, 0x3E, 0x66, 0x3B, 0x00
	db 0xCC, 0x00, 0x78, 0x0C, 0x7C, 0xCC, 0x76, 0x00
	db 0xE0, 0x00, 0x78, 0x0C, 0x7C, 0xCC, 0x76, 0x00
	db 0x30, 0x30, 0x78, 0x0C, 0x7C, 0xCC, 0x76, 0x00
	db 0x00, 0x00, 0x7C, 0xC6, 0xC0, 0x78, 0x0C, 0x38
	db 0x7E, 0x81, 0x3C, 0x66, 0x7E, 0x60, 0x3C, 0x00
	db 0xCC, 0x00, 0x78, 0xCC, 0xFC, 0xC0, 0x78, 0x00
	db 0xE0, 0x00, 0x78, 0xCC, 0xFC, 0xC0, 0x78, 0x00
	db 0xCC, 0x00, 0x70, 0x30, 0x30, 0x30, 0x78, 0x00
	db 0x7C, 0x82, 0x38, 0x18, 0x18, 0x18, 0x3C, 0x00
	db 0xE0, 0x00, 0x70, 0x30, 0x30, 0x30, 0x78, 0x00
	db 0xC6, 0x10, 0x7C, 0xC6, 0xFE, 0xC6, 0xC6, 0x00
	db 0x30, 0x30, 0x00, 0x78, 0xCC, 0xFC, 0xCC, 0x00
	db 0x1C, 0x00, 0xFC, 0x60, 0x78, 0x60, 0xFC, 0x00
	db 0x00, 0x00, 0x7F, 0x0C, 0x7F, 0xCC, 0x7F, 0x00
	db 0x3E, 0x6C, 0xCC, 0xFE, 0xCC, 0xCC, 0xCE, 0x00
	db 0x78, 0x84, 0x00, 0x78, 0xCC, 0xCC, 0x78, 0x00
	db 0x00, 0xCC, 0x00, 0x78, 0xCC, 0xCC, 0x78, 0x00
	db 0x00, 0xE0, 0x00, 0x78, 0xCC, 0xCC, 0x78, 0x00
	db 0x78, 0x84, 0x00, 0xCC, 0xCC, 0xCC, 0x76, 0x00
	db 0x00, 0xE0, 0x00, 0xCC, 0xCC, 0xCC, 0x76, 0x00
	db 0x00, 0xCC, 0x00, 0xCC, 0xCC, 0x7C, 0x0C, 0xF8
	db 0xC3, 0x18, 0x3C, 0x66, 0x66, 0x3C, 0x18, 0x00
	db 0xCC, 0x00, 0xCC, 0xCC, 0xCC, 0xCC, 0x78, 0x00
	db 0x18, 0x18, 0x7E, 0xC0, 0xC0, 0x7E, 0x18, 0x18
	db 0x38, 0x6C, 0x64, 0xF0, 0x60, 0xE6, 0xFC, 0x00
	db 0xCC, 0xCC, 0x78, 0x30, 0xFC, 0x30, 0xFC, 0x30
	db 0xF8, 0xCC, 0xCC, 0xFA, 0xC6, 0xCF, 0xC6, 0xC3
	db 0x0E, 0x1B, 0x18, 0x3C, 0x18, 0x18, 0xD8, 0x70
	db 0x1C, 0x00, 0x78, 0x0C, 0x7C, 0xCC, 0x76, 0x00
	db 0x38, 0x00, 0x70, 0x30, 0x30, 0x30, 0x78, 0x00
	db 0x00, 0x1C, 0x00, 0x78, 0xCC, 0xCC, 0x78, 0x00
	db 0x00, 0x1C, 0x00, 0xCC, 0xCC, 0xCC, 0x76, 0x00
	db 0x00, 0xF8, 0x00, 0xB8, 0xCC, 0xCC, 0xCC, 0x00
	db 0xFC, 0x00, 0xCC, 0xEC, 0xFC, 0xDC, 0xCC, 0x00
	db 0x3C, 0x6C, 0x6C, 0x3E, 0x00, 0x7E, 0x00, 0x00
	db 0x38, 0x6C, 0x6C, 0x38, 0x00, 0x7C, 0x00, 0x00
	db 0x18, 0x00, 0x18, 0x18, 0x30, 0x66, 0x3C, 0x00
	db 0x00, 0x00, 0x00, 0xFC, 0xC0, 0xC0, 0x00, 0x00
	db 0x00, 0x00, 0x00, 0xFC, 0x0C, 0x0C, 0x00, 0x00
	db 0xC6, 0xCC, 0xD8, 0x36, 0x6B, 0xC2, 0x84, 0x0F
	db 0xC3, 0xC6, 0xCC, 0xDB, 0x37, 0x6D, 0xCF, 0x03
	db 0x18, 0x00, 0x18, 0x18, 0x3C, 0x3C, 0x18, 0x00
	db 0x00, 0x33, 0x66, 0xCC, 0x66, 0x33, 0x00, 0x00
	db 0x00, 0xCC, 0x66, 0x33, 0x66, 0xCC, 0x00, 0x00
	db 0x22, 0x88, 0x22, 0x88, 0x22, 0x88, 0x22, 0x88
	db 0x55, 0xAA, 0x55, 0xAA, 0x55, 0xAA, 0x55, 0xAA
	db 0xDB, 0xF6, 0xDB, 0x6F, 0xDB, 0x7E, 0xD7, 0xED
	db 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18
	db 0x18, 0x18, 0x18, 0x18, 0xF8, 0x18, 0x18, 0x18
	db 0x18, 0x18, 0xF8, 0x18, 0xF8, 0x18, 0x18, 0x18
	db 0x36, 0x36, 0x36, 0x36, 0xF6, 0x36, 0x36, 0x36
	db 0x00, 0x00, 0x00, 0x00, 0xFE, 0x36, 0x36, 0x36
	db 0x00, 0x00, 0xF8, 0x18, 0xF8, 0x18, 0x18, 0x18
	db 0x36, 0x36, 0xF6, 0x06, 0xF6, 0x36, 0x36, 0x36
	db 0x36, 0x36, 0x36, 0x36, 0x36, 0x36, 0x36, 0x36
	db 0x00, 0x00, 0xFE, 0x06, 0xF6, 0x36, 0x36, 0x36
	db 0x36, 0x36, 0xF6, 0x06, 0xFE, 0x00, 0x00, 0x00
	db 0x36, 0x36, 0x36, 0x36, 0xFE, 0x00, 0x00, 0x00
	db 0x18, 0x18, 0xF8, 0x18, 0xF8, 0x00, 0x00, 0x00
	db 0x00, 0x00, 0x00, 0x00, 0xF8, 0x18, 0x18, 0x18
	db 0x18, 0x18, 0x18, 0x18, 0x1F, 0x00, 0x00, 0x00
	db 0x18, 0x18, 0x18, 0x18, 0xFF, 0x00, 0x00, 0x00
	db 0x00, 0x00, 0x00, 0x00, 0xFF, 0x18, 0x18, 0x18
	db 0x18, 0x18, 0x18, 0x18, 0x1F, 0x18, 0x18, 0x18
	db 0x00, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x00, 0x00
	db 0x18, 0x18, 0x18, 0x18, 0xFF, 0x18, 0x18, 0x18
	db 0x18, 0x18, 0x1F, 0x18, 0x1F, 0x18, 0x18, 0x18
	db 0x36, 0x36, 0x36, 0x36, 0x37, 0x36, 0x36, 0x36
	db 0x36, 0x36, 0x37, 0x30, 0x3F, 0x00, 0x00, 0x00
	db 0x00, 0x00, 0x3F, 0x30, 0x37, 0x36, 0x36, 0x36
	db 0x36, 0x36, 0xF7, 0x00, 0xFF, 0x00, 0x00, 0x00
	db 0x00, 0x00, 0xFF, 0x00, 0xF7, 0x36, 0x36, 0x36
	db 0x36, 0x36, 0x37, 0x30, 0x37, 0x36, 0x36, 0x36
	db 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00
	db 0x36, 0x36, 0xF7, 0x00, 0xF7, 0x36, 0x36, 0x36
	db 0x18, 0x18, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00
	db 0x36, 0x36, 0x36, 0x36, 0xFF, 0x00, 0x00, 0x00
	db 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x18, 0x18, 0x18
	db 0x00, 0x00, 0x00, 0x00, 0xFF, 0x36, 0x36, 0x36
	db 0x36, 0x36, 0x36, 0x36, 0x3F, 0x00, 0x00, 0x00
	db 0x18, 0x18, 0x1F, 0x18, 0x1F, 0x00, 0x00, 0x00
	db 0x00, 0x00, 0x1F, 0x18, 0x1F, 0x18, 0x18, 0x18
	db 0x00, 0x00, 0x00, 0x00, 0x3F, 0x36, 0x36, 0x36
	db 0x36, 0x36, 0x36, 0x36, 0xFF, 0x36, 0x36, 0x36
	db 0x18, 0x18, 0xFF, 0x18, 0xFF, 0x18, 0x18, 0x18
	db 0x18, 0x18, 0x18, 0x18, 0xF8, 0x00, 0x00, 0x00
	db 0x00, 0x00, 0x00, 0x00, 0x1F, 0x18, 0x18, 0x18
	db 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF
	db 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF
	db 0xF0, 0xF0, 0xF0, 0xF0, 0xF0, 0xF0, 0xF0, 0xF0
	db 0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F
	db 0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00
	db 0x00, 0x00, 0x76, 0xDC, 0xC8, 0xDC, 0x76, 0x00
	db 0x00, 0x78, 0xCC, 0xF8, 0xCC, 0xF8, 0xC0, 0xC0
	db 0x00, 0xFC, 0xCC, 0xC0, 0xC0, 0xC0, 0xC0, 0x00
	db 0x00, 0x00, 0xFE, 0x6C, 0x6C, 0x6C, 0x6C, 0x00
	db 0xFC, 0xCC, 0x60, 0x30, 0x60, 0xCC, 0xFC, 0x00
	db 0x00, 0x00, 0x7E, 0xD8, 0xD8, 0xD8, 0x70, 0x00
	db 0x00, 0x66, 0x66, 0x66, 0x66, 0x7C, 0x60, 0xC0
	db 0x00, 0x76, 0xDC, 0x18, 0x18, 0x18, 0x18, 0x00
	db 0xFC, 0x30, 0x78, 0xCC, 0xCC, 0x78, 0x30, 0xFC
	db 0x38, 0x6C, 0xC6, 0xFE, 0xC6, 0x6C, 0x38, 0x00
	db 0x38, 0x6C, 0xC6, 0xC6, 0x6C, 0x6C, 0xEE, 0x00
	db 0x1C, 0x30, 0x18, 0x7C, 0xCC, 0xCC, 0x78, 0x00
	db 0x00, 0x00, 0x7E, 0xDB, 0xDB, 0x7E, 0x00, 0x00
	db 0x06, 0x0C, 0x7E, 0xDB, 0xDB, 0x7E, 0x60, 0xC0
	db 0x38, 0x60, 0xC0, 0xF8, 0xC0, 0x60, 0x38, 0x00
	db 0x78, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0x00
	db 0x00, 0x7E, 0x00, 0x7E, 0x00, 0x7E, 0x00, 0x00
	db 0x18, 0x18, 0x7E, 0x18, 0x18, 0x00, 0x7E, 0x00
	db 0x60, 0x30, 0x18, 0x30, 0x60, 0x00, 0xFC, 0x00
	db 0x18, 0x30, 0x60, 0x30, 0x18, 0x00, 0xFC, 0x00
	db 0x0E, 0x1B, 0x1B, 0x18, 0x18, 0x18, 0x18, 0x18
	db 0x18, 0x18, 0x18, 0x18, 0x18, 0xD8, 0xD8, 0x70
	db 0x18, 0x18, 0x00, 0x7E, 0x00, 0x18, 0x18, 0x00
	db 0x00, 0x76, 0xDC, 0x00, 0x76, 0xDC, 0x00, 0x00
	db 0x38, 0x6C, 0x6C, 0x38, 0x00, 0x00, 0x00, 0x00
	db 0x00, 0x00, 0x00, 0x18, 0x18, 0x00, 0x00, 0x00
	db 0x00, 0x00, 0x00, 0x00, 0x18, 0x00, 0x00, 0x00
	db 0x0F, 0x0C, 0x0C, 0x0C, 0xEC, 0x6C, 0x3C, 0x1C
	db 0x58, 0x6C, 0x6C, 0x6C, 0x6C, 0x00, 0x00, 0x00
	db 0x70, 0x98, 0x30, 0x60, 0xF8, 0x00, 0x00, 0x00
	db 0x00, 0x00, 0x3C, 0x3C, 0x3C, 0x3C, 0x00, 0x00
	db 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
