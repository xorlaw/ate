; ate — the assembly text editor

bits 64
default rel                 

; syscall numbers
%define SYS_READ        0
%define SYS_WRITE       1
%define SYS_OPEN        2
%define SYS_CLOSE       3
%define SYS_FSTAT       5
%define SYS_MMAP        9
%define SYS_MUNMAP      11
%define SYS_BRK         12
%define SYS_IOCTL       16
%define SYS_EXIT        60

; open flags 
%define O_RDONLY        0
%define O_WRONLY        1
%define O_RDWR          2
%define O_CREAT         0x40
%define O_TRUNC         0x200

; mmap flags 
%define PROT_READ       0x1
%define PROT_WRITE      0x2
%define MAP_PRIVATE     0x2
%define MAP_ANONYMOUS   0x20
%define MAP_FAILED      -1          ; mmap returns this on error

; ioctl / termios 
%define TCGETS          0x5401      ; get terminal attributes
%define TCSETS          0x5402      ; set terminal attributes
%define ICANON          0x2         ; canonical mode flag 
%define ECHO            0x8         ; echo input to screen

; ANSI escape sequences
%define ESC             0x1b        ; ACSII escape character 

; editor limits
%define BUF_INIT_SIZE   655535      ; 64kb initial gap buffer
%define GAP_MIN_SIZE    1024        ; minimum gap we always maintain
%define MAX_COLS        512         ; max terminal width we handle 
%define MAX_ROWS        256         ; max terminal height we handle

; keycodes
%define KEY_CTRL_Q      0x11        ; ctrl + q - quit 
%define KEY_CTRL_S      0x13        ; ctrl + s - save
%define KEY_CTRL_H      0x08        ; ctrl + h / backspace
%define KEY_DEL         0x7f        ; del key as most terminals send this for backspace
%define KEY_ESCAPE      0x1b        ; esc key
%define KEY_ENTER       0x0a        ; newline / enter
%define KEY_RETURN      0x0d        ; carriage return


; .data section
section .data
    
     ; error / status strings

     err_usage          db "usage: ate <file>", 0x0a
     err_usage_len      equ $ - err_usage

     err_open           db "ate: cannot open file", 0x0a
     err_open_len       equ $ - err_open

     err_mmap           db "ate: mmap failed", 0x0a
     err_mmap_len       equ $ - err_mmap

     err_term           db "ate: not a terminal", 0x0a
     err_term_len       equ $ - err_term

     err_write          db "ate: write failed", 0x0a
     err_write_len      equ $ - err_write

     msg_saved          db " -- saved --"
     msg_saved_len      equ $ - msg_saved

     ; ANSI control strings
     
     ; hide / show cursor, prevents flickering during redraws
     cur_hide           db  ESC, "[?25l"
     cur_hide_len       equ $ - cur_hide

     cur_show           db  ESC, "[?25h"
     cur_show_len       equ $ - cur_show

     ; move cursor to top left of screen
     cur_home           db  ESC, "[H"
     cur_home_len       equ $ - cur_home

     ; clear from cursor to end of line (for redrawing)
     clr_eol            db  ESC, "[K"
     clr_eol_len        equ $ - clr_eol

     ; clear entire screen
     clr_screen         db  ESC, "2[J"
     clr_screen_len     equ $ - clr_screen

     ; request cursor position report - used to detect terminal dimensions
     req_cursor_pos     db  ESC, "[6n"
     req_cursor_pos_len equ $ - req_cursor_pos

     ; status bar seperator
     bar_sep            db  ESC, "[7m"
     bar_sep_len        equ $ - bar_sep
     bar_sep_end        db  ESC, "[m"
     bar_sep_end_len    equ $ - bar_sep_end


; .bss section 
section .bss
     


     ; terminal state
     TERMIOS_SIZE   equ 60
     orig_termios   resb TERMIOS_SIZE   ; saved terminal state
     raw_termios    resb TERMIOS_SIZE   

     ; terminal dimensions
     term_rows      resw 1              ; screen height in rows
     term_cols      resw 1              ; screen width in columns

     ; gap buffer
     buf_start      resq 1              ; pointer to start of buffer
     buf_end        resq 1              ; pointer to one past end of buffer
     gap_start      resq 1              ; pointer to first byte of gap
     gap_end        resq 1              ; pointer to one past end of gap

     ; cursor / view state
     cur_row        resq 1              ; cursor row, 0-indexed
     cur_col        resq 1              ; cursor col, 0-indexed
     view_row       resq 1              ; topmost visible row for scrolling

     ; file state
     file_fd        resq 1              ; file descriptor, -1 means no file is open
     filename_ptr   resq 1              ; pointer to filename string
     filename_len   resq 1              ; byte length of filename

     ; dirty flag
     dirty          resb 1              ; 1 means unsaved changes, 0 means clean

     ; scratch / render buffer
     row_buf        resb MAX_COLS + 64  ; +64 for ANSI escape overhead
     row_buf_len    resq 1 

     ; input read buffer
     key_buf        resb 8               ; raw bytes from read
     key_buf_len    resq 1 


; .text section ( executable code ) 
section .text
global _start

_start:
     ; validate argument count
     mov    rdi, [rsp]
     cmp    rdi, 2
     jne    .bad_usage

     ; store filename pointer
     mov    rax, [rsp + 16]
     mov    [filename_ptr], rax

     ; compute filename length (without libc)
     xor    rcx, rcx
.strlen_loop:
     cmp    byte [rax + rcx], 0
     je     .strlen_done
     inc    rcx
     jmp    .strlen_loop
.strlen_done:
     mov    [filename_len], rcx
    
     ; check stdin is a terminal
     ; if it isnt a tty we exit cleanly
     mov    rax, SYS_IOCTL
     mov    rdi, 0
     mov    rsi, TCGETS
     lea    rdx, [orig_termios]
     syscall
     cmp    rax, 0
     jl    .not_a_tty
     
     ; copy orig_termios to raw_termios
     lea    rsi, [orig_termios]
     lea    rdi, [raw_termios]
     mov    rcx, TERMIOS_SIZE
     rep movsb
     
     ; call init routines
     call   term_raw_enable
     cll    term_get_size
     call   buf_init
     call   file_open_or_new
     call   editor_run      

     ; start error paths

.bad_usage:
     mov    rax, SYS_WRITE
     mov    rdi, 2              ; STDERR_FILENO
     lea    rsi, [err_usage]
     mov    rdx, err_usage_len  
     syscall
     mov    rdi, 1
     jmp    exit_editor

.not_a_tty:
     mov    rax, SYS_WRITE
     mov    rdi, 2
     lea    rsi, [err_term]
     mov    rdx, err_term_len
     syscall
     mov    rdi, 1
     jmp    exit_editor 








