@ECHO OFF
TITLE Compile OrchidOS
COLOR 4E
CLS
SET DEPENDENCY_MISSING=FALSE
SET NEEDED_DEPENDENCIES=

:: This batch file assumes the compilation is happening on a Windows platform, with a DD for Windows utility.
:: ---> DD for Windows: http://www.chrysocome.net/dd

:: Check whether or not the 'bin' directory exists.
:: ---> If not, create it.
IF NOT EXIST "..\bin" (MKDIR "..\bin")

:: A quick test of dependencies before doing anything.
2>nul nasm --h
IF ERRORLEVEL 9009 (SET DEPENDENCY_MISSING=TRUE&SET NEEDED_DEPENDENCIES=1
) ELSE (SET NEEDED_DEPENDENCIES=0)
2>nul dd /?
IF ERRORLEVEL 9009 (SET DEPENDENCY_MISSING=TRUE&SET NEEDED_DEPENDENCIES=%NEEDED_DEPENDENCIES% 1
) ELSE (SET NEEDED_DEPENDENCIES=%NEEDED_DEPENDENCIES% 0)
2>nul qemu-system-i386 /?
IF ERRORLEVEL 9009 (SET DEPENDENCY_MISSING=TRUE&SET NEEDED_DEPENDENCIES=%NEEDED_DEPENDENCIES% 1
) ELSE (SET NEEDED_DEPENDENCIES=%NEEDED_DEPENDENCIES% 0)
IF "%DEPENDENCY_MISSING%"=="TRUE" GOTO MISSING_DEP

:: Compile OS source into raw binaries with NASM.
ECHO ======================================
ECHO Compiling Operating System binaries...
nasm ".\core\BOOT.asm" -f bin -o "..\bin\boot.bin"
nasm ".\core\BOOT_ST2.asm" -f bin -o "..\bin\boot2.bin"
nasm ".\core\KERNEL.asm" -f bin -o "..\bin\kernel.bin"
ECHO ======================================
ECHO.

:: Create the image to use.
ECHO ======================================
ECHO Creating MBR boot image...
DEL /f /q "..\bin\image.img"
dd if="..\bin\boot.bin" of="..\bin\image.img" bs=512
ECHO ======================================
ECHO.

:: Add stage-two loader (AKA ST2).
ECHO ======================================
ECHO Creating second-stage loader...
dd if="..\bin\boot2.bin" of="..\bin\image.img" bs=512 seek=1
ECHO ======================================
ECHO.

:: Append the ST2 with the kernel code...
ECHO ======================================
ECHO Appending kernel onto image...
dd if="..\bin\kernel.bin" of="..\bin\image.img" bs=512 seek=3
:: Delete the raw binaries and leave the image release.
DEL /f /q "..\bin\boot.bin"
DEL /f /q "..\bin\boot2.bin"
DEL /f /q "..\bin\kernel.bin"
ECHO ======================================

ECHO.
ECHO.
CHOICE /C YN /M "Would you like to test the bootable image with QEMU?"
IF ERRORLEVEL 2 GOTO EXIT_COMPILER
:: Emulate an x86_64 system with 8GB of RAM (feel free to change this).
qemu-system-x86_64 ^
    -m 8G -usb -device usb-ehci,id=ehci ^
    -device isa-debug-exit,iobase=0xF4,iosize=0x04 ^
    -netdev user,id=eth0,net=10.0.2.0/24,dhcpstart=10.0.2.6,hostfwd=tcp::5555-:22 ^
    -device e1000,netdev=eth0,mac=11:22:33:44:55:66 ^
    -drive format=raw,index=0,file="../bin/image.img" ^
    -object filter-dump,id=eth0,netdev=eth0,file="%USERPROFILE%/Documents/QEMUDUMP.txt"
GOTO EXIT_COMPILER

:MISSING_DEP
FOR /F "usebackq tokens=1,2* delims= " %%a IN (`ECHO %NEEDED_DEPENDENCIES%`) DO (
    IF x%%a==x0 (SET NASM_FOUND=found) ELSE (SET NASM_FOUND=--MISSING--)
    IF x%%b==x0 (SET DD_FOUND=found) ELSE (SET DD_FOUND=--MISSING--)
    IF x%%c==x0 (SET QEMU_FOUND=found) ELSE (SET QEMU_FOUND=--MISSING--)
)
ECHO You are missing one of more of the compiler's dependencies^!
ECHO.
ECHO 1.) NASM: %NASM_FOUND%
ECHO 2.) DD for Windows: %DD_FOUND%
ECHO 3.) QEMU-SYSTEM-i386: %QEMU_FOUND%
ECHO.
ECHO.
ECHO These have registered as missing becuase the command processor could not find them.
ECHO --Please check your Windows PATH environment variable to ensure the dependencies will be found.
ECHO.
ECHO Your PATH variable:
PATH
ECHO.
ECHO.
ECHO.
PAUSE
SET NASM_FOUND=
SET DD_FOUND=
SET QEMU_FOUND=

:EXIT_COMPILER
SET NEEDED_DEPENDENCIES=
SET DEPENDENCY_MISSING=
COLOR
GOTO :EOF
