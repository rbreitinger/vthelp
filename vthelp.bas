' ============================================================
' VTHELP.BAS  --  DOS-style .vth help file viewer
' Requires: VT library (vt/vt.bi), FreeBASIC 1.10.1
' Usage:    vthelp.exe myfile.vth
' ============================================================
#cmdline "-s gui -gen gcc -O 2"
#Include Once "vt/vt.bi"

Const VTH_VERSION = "1.0.1"
' ------------------------------------------------------------
' Layout constants  (VT_SCREEN_12 = 80x30)
' ------------------------------------------------------------
Const HLP_ROWS   = 30         ' screen rows
Const HLP_COLS   = 80         ' screen cols
Const HLP_IDX_W  = 22         ' index pane width, cols 1..22
Const HLP_DIV_C  = 23         ' divider column
Const HLP_CNT_C  = 24         ' content pane first column
Const HLP_CNT_W  = 57         ' content pane width, cols 24..80
Const HLP_PNL_T  = 2          ' pane top row (below top bar)
Const HLP_PNL_B  = 29         ' pane bottom row (above bottom bar)
Const HLP_PNL_H  = 28         ' HLP_PNL_B - HLP_PNL_T + 1
Const HLP_BACK_M = 32         ' maximum back-stack depth
Const HLP_TXT_W  = 55         ' usable reflow width inside content pane

' ------------------------------------------------------------
' Color constants
' ------------------------------------------------------------
Const C_BG     = VT_BLACK
Const C_BODY   = VT_LIGHT_GREY
Const C_TITLE  = VT_WHITE
Const C_GRP    = VT_WHITE
Const C_SEL_F  = VT_BLACK
Const C_SEL_B  = VT_LIGHT_GREY
Const C_DSEL_F = VT_WHITE
Const C_DSEL_B = VT_DARK_GREY
Const C_SEC    = VT_WHITE
Const C_CODE   = VT_BRIGHT_GREEN
Const C_LINK   = VT_BRIGHT_BLUE
Const C_LKHI_F = VT_BLACK
Const C_LKHI_B = VT_GREEN
Const C_BAR_F  = VT_BLACK
Const C_BAR_B  = VT_CYAN

' ------------------------------------------------------------
' Data types
' ------------------------------------------------------------
Type hlp_topic
    tname  As String   ' :topic value  (index key)
    tshort As String   ' :short value  (one-liner for index)
    tgroup As String   ' :group value
    tbody  As String   ' raw body text; :tag markers kept verbatim
End Type

Type hlp_line
    txt     As String
    is_code As Byte    ' 1 = verbatim/code (syntax, params, example)
    is_head As Byte    ' 1 = section header line
    is_link As Byte    ' 1 = see-also entry
End Type

Type hlp_link
    ridx As Long       ' index into rlines() this link occupies
    cs   As Long       ' col_start: 1-based char pos within txt
    ce   As Long       ' col_end:   inclusive
    tgt  As String     ' target topic name
End Type

Type hlp_bentry
    tidx  As Long      ' topic index at time of navigation
    topln As Long      ' content scroll offset at time of navigation
End Type

Type hlp_ientry
    is_grp As Byte     ' 1 = group header row
    tidx   As Long     ' topic index, or -1 for group headers
    disp   As String   ' display text (not padded)
End Type

' ------------------------------------------------------------
' Global state
' ------------------------------------------------------------
Dim Shared topics()  As hlp_topic
Dim Shared ntopics   As Long

Dim Shared grps()    As String
Dim Shared ngrps     As Long

Dim Shared rlines()  As hlp_line    ' rendered content lines
Dim Shared nrlines   As Long
Dim Shared top_ln    As Long        ' content pane scroll offset

Dim Shared lnks()    As hlp_link    ' see-also / cross-ref links
Dim Shared nlnks     As Long
Dim Shared focus_lnk As Long        ' keyboard-focused link (-1 = none)

Dim Shared bstk()    As hlp_bentry  ' navigation back stack
Dim Shared bstk_d    As Long        ' back-stack depth

Dim Shared ilst()    As hlp_ientry  ' flat index list (groups + topics)
Dim Shared nilst     As Long

Dim Shared cur_top   As Long        ' currently displayed topic index
Dim Shared cur_pane  As Long        ' 0 = index pane, 1 = content pane
Dim Shared idx_sel   As Long        ' selected flat-list entry
Dim Shared idx_top   As Long        ' index pane scroll offset
Dim Shared hlp_disp  As String      ' filename shown in top bar

' ============================================================
' Utility helpers
' ============================================================

Function str_trim(s As String) As String
    Dim i As Long = 1, j As Long = Len(s)
    Do While i <= j
        Dim ch As UByte = s[i - 1]
        If ch = 32 Or ch = 9 Then i += 1 Else Exit Do
    Loop
    Do While j >= i
        Dim ch As UByte = s[j - 1]
        If ch = 32 Or ch = 9 Then j -= 1 Else Exit Do
    Loop
    If i > j Then Return ""
    Return Mid(s, i, j - i + 1)
End Function

Function path_base(p As String) As String
    Dim i As Long
    For i = Len(p) To 1 Step -1
        If Mid(p, i, 1) = "/" Or Mid(p, i, 1) = "\" Then Return Mid(p, i + 1)
    Next
    Return p
End Function

Function find_topic_n(nm As String) As Long
    Dim i As Long
    For i = 0 To ntopics - 1
        If topics(i).tname = nm Then Return i
    Next
    Return -1
End Function

Function find_grp_i(nm As String) As Long
    Dim i As Long
    For i = 0 To ngrps - 1
        If grps(i) = nm Then Return i
    Next
    Return -1
End Function

Sub add_grp(nm As String)
    If find_grp_i(nm) >= 0 Then Exit Sub
    If ngrps > UBound(grps) Then ReDim Preserve grps(ngrps + 7)
    grps(ngrps) = nm
    ngrps += 1
End Sub

' ============================================================
' Parser  --  reads .vth file into topics() / grps() arrays
' ============================================================

' Store one completed topic into global arrays
Sub store_topic(ByRef t As hlp_topic, ByRef in_top As Byte)
    If in_top = 0 Or t.tname = "" Then Exit Sub
    If t.tgroup = "" Then t.tgroup = "General"
    ' Strip leading blank lines that accumulate between :group and body text
    Do While Left(t.tbody, 1) = Chr(10)
        t.tbody = Mid(t.tbody, 2)
    Loop
    add_grp t.tgroup
    If ntopics > UBound(topics) Then ReDim Preserve topics(ntopics + 15)
    topics(ntopics) = t
    ntopics += 1
    in_top = 0
End Sub

Sub hlp_load(fname As String)
    Dim fh As Long = FreeFile
    If Open(fname For Input As #fh) <> 0 Then
        Print "vthelp: cannot open '" & fname & "'"
        End 1
    End If

    ntopics = 0 : ngrps = 0
    ReDim topics(15) As hlp_topic
    ReDim grps(7)    As String

    Dim in_top  As Byte   = 0
    Dim cur_tag As String = ""
    Dim t       As hlp_topic
    Dim fln     As String    ' current file line

    Do While Not EOF(fh)
        Line Input #fh, fln

        ' Skip comment lines outside :example blocks
        If cur_tag <> "example" And Left(fln, 1) = "'" Then Continue Do

        If Left(fln, 1) = ":" Then
            ' Parse tag name and optional rest
            Dim sp   As Long   = InStr(2, fln, " ")
            Dim stag As String
            Dim rest As String
            If sp = 0 Then
                stag = LCase(Mid(fln, 2))
                rest = ""
            Else
                stag = LCase(Mid(fln, 2, sp - 2))
                rest = str_trim(Mid(fln, sp + 1))
            End If

            ' Inside :example only :topic is special;
            ' all other : lines are stored verbatim as code
            If cur_tag = "example" And stag <> "topic" Then
                If in_top Then t.tbody &= fln & Chr(10)
                Continue Do
            End If

            Select Case stag
            Case "topic"
                store_topic t, in_top
                t.tname  = rest
                t.tshort = ""
                t.tgroup = ""
                t.tbody  = ""
                in_top   = 1
                cur_tag  = ""

            Case "short"
                If in_top Then t.tshort = rest

            Case "group"
                If in_top Then t.tgroup = rest

            Case "syntax", "params", "notes", "example", "see"
                If in_top Then
                    t.tbody &= ":" & stag & Chr(10)
                    cur_tag = stag
                End If

            Case Else
                ' Unknown tag: store in body as-is
                If in_top Then t.tbody &= fln & Chr(10)
            End Select
        Else
            If in_top Then t.tbody &= fln & Chr(10)
        End If
    Loop

    store_topic t, in_top
    Close #fh
End Sub

' ============================================================
' Index flat-list builder
' ============================================================

Sub build_ilst()
    nilst = 0
    ReDim ilst(ntopics + ngrps) As hlp_ientry

    Dim gi As Long, ti As Long
    For gi = 0 To ngrps - 1
        ' Group header row
        ilst(nilst).is_grp = 1
        ilst(nilst).tidx   = -1
        ilst(nilst).disp   = grps(gi)
        nilst += 1
        ' Topics in this group, in file order
        For ti = 0 To ntopics - 1
            If topics(ti).tgroup = grps(gi) Then
                ilst(nilst).is_grp = 0
                ilst(nilst).tidx   = ti
                ilst(nilst).disp   = topics(ti).tname
                nilst += 1
            End If
        Next
    Next
End Sub

' Return flat-list index of a given topic index (0-based)
Function ilst_find(ti As Long) As Long
    Dim i As Long
    For i = 0 To nilst - 1
        If ilst(i).is_grp = 0 And ilst(i).tidx = ti Then Return i
    Next
    Return 0
End Function

' ============================================================
' Renderer helpers  (all operate on the global rlines / lnks arrays)
' ============================================================

Sub rl_add(txt As String, is_code As Byte, is_head As Byte, is_link As Byte)
    If nrlines > UBound(rlines) Then ReDim Preserve rlines(nrlines + 63)
    rlines(nrlines).txt     = txt
    rlines(nrlines).is_code = is_code
    rlines(nrlines).is_head = is_head
    rlines(nrlines).is_link = is_link
    nrlines += 1
End Sub

' Add a blank render line, but collapse consecutive blanks
Sub rl_blank()
    If nrlines > 0 Then
        If rlines(nrlines - 1).txt = "" And rlines(nrlines - 1).is_head = 0 Then Exit Sub
    End If
    rl_add "", 0, 0, 0
End Sub

' Flush the word-wrap accumulator as a body line
Sub rl_flush(ByRef wbuf As String)
    If wbuf = "" Then Exit Sub
    rl_add wbuf, 0, 0, 0
    wbuf = ""
End Sub

' Output a verbatim code line, word-wrapping at HLP_TXT_W.
' Searches backwards for the last space so words are never split.
' Continuation lines are indented 8 spaces (one tab stop) so they align
' naturally under the description column of name-padded param blocks.
Sub rl_verbwrap(src As String)
    Dim s    As String = src
    Dim cont As String = Space(8)
    Do While Len(s) > HLP_TXT_W
        ' Find last space at or before the wrap column
        Dim brk As Long = 0
        Dim ii  As Long
        For ii = HLP_TXT_W To 1 Step -1
            If Mid(s, ii, 1) = " " Then brk = ii : Exit For
        Next
        If brk = 0 Then brk = HLP_TXT_W   ' no space found: hard break
        rl_add Left(s, brk), 1, 0, 0
        s = cont & str_trim(Mid(s, brk + 1))
    Loop
    If s <> "" Then rl_add s, 1, 0, 0
End Sub

' Feed one word into the word-wrap accumulator
Sub rl_word(ByRef wbuf As String, wd As String)
    If wd = "" Then Exit Sub
    If wbuf = "" Then
        wbuf = wd
    ElseIf Len(wbuf) + 1 + Len(wd) <= HLP_TXT_W Then
        wbuf &= " " & wd
    Else
        rl_add wbuf, 0, 0, 0
        wbuf = wd
    End If
End Sub

' Reflow a single source line into the word accumulator.
' Blank source lines flush + add a paragraph-break blank render line.
Sub rl_reflow(src As String, ByRef wbuf As String)
    Dim s As String = str_trim(src)
    If s = "" Then
        rl_flush wbuf
        rl_blank
        Exit Sub
    End If
    Dim wpos As Long = 1
    Do While wpos <= Len(s)
        Dim sp As Long = InStr(wpos, s, " ")
        Dim wd As String
        If sp = 0 Then
            wd   = Mid(s, wpos)
            wpos = Len(s) + 1
        Else
            wd   = Mid(s, wpos, sp - wpos)
            wpos = sp + 1
        End If
        rl_word wbuf, wd
    Loop
End Sub

Sub lnk_add(ri As Long, cs As Long, ce As Long, tgt As String)
    If nlnks > UBound(lnks) Then ReDim Preserve lnks(nlnks + 15)
    lnks(nlnks).ridx = ri
    lnks(nlnks).cs   = cs
    lnks(nlnks).ce   = ce
    lnks(nlnks).tgt  = tgt
    nlnks += 1
End Sub

' ============================================================
' Topic renderer  --  builds rlines() + lnks() for topic ti
' ============================================================
Sub hlp_render(ti As Long)
    nrlines    = 0
    nlnks      = 0
    focus_lnk  = -1
    top_ln     = 0
    ReDim rlines(127) As hlp_line
    ReDim lnks(15)    As hlp_link

    If ti < 0 Or ti >= ntopics Then Exit Sub

    ' --- Header block: title + short + blank ---
    rl_add topics(ti).tname, 0, 1, 0
    If topics(ti).tshort <> "" Then rl_add topics(ti).tshort, 0, 0, 0
    rl_blank

    ' --- Body pass ---
    Dim tbody As String = topics(ti).tbody
    Dim blen  As Long   = Len(tbody)
    Dim bpos  As Long   = 1
    Dim stag  As String = ""
    Dim wbuf  As String = ""

    Do While bpos <= blen
        ' Extract next line from body
        Dim eol As Long = InStr(bpos, tbody, Chr(10))
        Dim bln As String
        If eol = 0 Then
            bln  = Mid(tbody, bpos)
            bpos = blen + 1
        Else
            bln  = Mid(tbody, bpos, eol - bpos)
            bpos = eol + 1
        End If

        ' --- Section tag line ---
        If Left(bln, 1) = ":" Then
            rl_flush wbuf
            stag = LCase(Mid(bln, 2))

            ' Blank line before section header (deduped by rl_blank)
            rl_blank

            ' Build header text: name + fill dashes to HLP_CNT_W
            Dim hdr As String
            Select Case stag
            Case "syntax"  : hdr = " Syntax "
            Case "params"  : hdr = " Parameters "
            Case "notes"   : hdr = " Notes "
            Case "example" : hdr = " Example "
            Case "see"     : hdr = " See also "
            Case Else      : hdr = " " & stag & " "
            End Select
            Dim fill As Long = HLP_CNT_W - Len(hdr)
            If fill < 0 Then fill = 0
            rl_add hdr & String(fill, Chr(196)), 0, 1, 0
            Continue Do
        End If

        ' --- Line content based on current section tag ---
        Select Case stag
        Case "syntax", "params", "example"
            ' Verbatim code line; soft-wrap if longer than content pane
            rl_verbwrap bln

        Case "notes"
            ' Notes treated as reflowed plain text
            rl_reflow bln, wbuf

        Case "see"
            ' One see-also entry per line
            Dim strim As String = str_trim(bln)
            If strim <> "" Then
                Dim ltxt As String = "  " & Chr(17) & " " & strim & " " & Chr(16)
                rl_add ltxt, 0, 0, 1
                ' Name starts at char pos 5 in ltxt
                lnk_add nrlines - 1, 5, 4 + Len(strim), strim
            End If

        Case Else
            ' Plain body text: reflow
            rl_reflow bln, wbuf
        End Select
    Loop

    rl_flush wbuf
End Sub

' ============================================================
' Navigation
' ============================================================

' Jump to topic and rebuild render state; does NOT touch back stack
Sub hlp_goto(ti As Long)
    If ti < 0 Or ti >= ntopics Then Exit Sub
    cur_top = ti
    hlp_render ti
    idx_sel = ilst_find(ti)
    If idx_sel < idx_top Then idx_top = idx_sel
    If idx_sel >= idx_top + HLP_PNL_H Then idx_top = idx_sel - HLP_PNL_H + 1
    If idx_top < 0 Then idx_top = 0
End Sub

' Navigate to topic, pushing current position to back stack
Sub hlp_navigate(ti As Long)
    If ti < 0 Or ti >= ntopics Then Exit Sub
    If bstk_d < HLP_BACK_M Then
        If bstk_d > UBound(bstk) Then ReDim Preserve bstk(bstk_d + 7)
        bstk(bstk_d).tidx  = cur_top
        bstk(bstk_d).topln = top_ln
        bstk_d += 1
    End If
    hlp_goto ti
End Sub

' Pop back stack and restore previous topic + scroll position
Sub hlp_back()
    If bstk_d = 0 Then Exit Sub
    bstk_d -= 1
    Dim saved_tl As Long = bstk(bstk_d).topln
    hlp_goto bstk(bstk_d).tidx
    ' Restore the previous scroll offset (hlp_goto resets it to 0)
    Dim max_tl As Long = nrlines - HLP_PNL_H
    If max_tl < 0 Then max_tl = 0
    top_ln = saved_tl
    If top_ln > max_tl Then top_ln = max_tl
End Sub

' ============================================================
' Scrolling helpers
' ============================================================

Sub scroll_cnt(delta As Long)
    Dim max_tl As Long = nrlines - HLP_PNL_H
    If max_tl < 0 Then max_tl = 0
    top_ln += delta
    If top_ln > max_tl Then top_ln = max_tl
    If top_ln < 0     Then top_ln = 0
End Sub

Sub scroll_idx(delta As Long)
    Dim max_it As Long = nilst - HLP_PNL_H
    If max_it < 0 Then max_it = 0
    idx_top += delta
    If idx_top > max_it Then idx_top = max_it
    If idx_top < 0      Then idx_top = 0
End Sub

' Scroll content pane so that focused link ridx is visible
Sub lnk_ensure_visible(li As Long)
    If li < 0 Or li >= nlnks Then Exit Sub
    Dim ri As Long = lnks(li).ridx
    If ri < top_ln Then
        top_ln = ri
    ElseIf ri >= top_ln + HLP_PNL_H Then
        top_ln = ri - HLP_PNL_H + 1
    End If
End Sub

' Move index selection by direction (+1 / -1), skipping group header rows.
' Also updates the content pane to preview the newly selected topic,
' without pushing a back-stack entry (that only happens on Enter/click).
Sub idx_move(direction As Long)
    Dim ns   As Long = idx_sel
    Dim orig As Long = idx_sel
    Do
        ns += direction
        If ns < 0      Then ns = orig : Exit Do
        If ns >= nilst Then ns = orig : Exit Do
        If ilst(ns).is_grp = 0 Then Exit Do   ' landed on a topic entry
    Loop
    idx_sel = ns
    If idx_sel < idx_top Then idx_top = idx_sel
    If idx_sel >= idx_top + HLP_PNL_H Then idx_top = idx_sel - HLP_PNL_H + 1
    If idx_top < 0 Then idx_top = 0
    ' Preview the newly highlighted topic in the content pane (no back-stack push)
    If idx_sel <> orig Then
        cur_top = ilst(idx_sel).tidx
        hlp_render ilst(idx_sel).tidx
        top_ln = 0
    End If
End Sub

' ============================================================
' Drawing routines
' ============================================================

' Fill one bar row with background color, print left/right labels
Sub draw_bar(row As Long, ltxt As String, rtxt As String)
    vt_color C_BAR_F, C_BAR_B
    vt_locate row, 1
    vt_print Space(HLP_COLS)
    vt_locate row, 2
    vt_print ltxt
    If rtxt <> "" Then
        vt_locate row, HLP_COLS - Len(rtxt) - 1
        vt_print rtxt
    End If
End Sub

Sub draw_chrome()
    ' Top bar: app name left, filename right
    draw_bar 1, "[ VTHELP " & VTH_VERSION & "]", "[ " & hlp_disp & " ]"
    
    ' Bottom bar: key hints
    draw_bar HLP_ROWS, "F1 Index  F2 Content  Tab/S+Tab Links  PgUp/PgDn  ESC Back", ""
    ' Vertical divider between index and content panes
    vt_color C_BODY, C_BG
    Dim rr As Long
    For rr = HLP_PNL_T To HLP_PNL_B
        vt_locate rr, HLP_DIV_C
        vt_print Chr(179)
    Next
End Sub

Sub draw_index()
    Dim rr As Long
    For rr = 0 To HLP_PNL_H - 1
        Dim ei  As Long = idx_top + rr
        Dim row As Long = HLP_PNL_T + rr
        vt_locate row, 1

        If ei < 0 Or ei >= nilst Then
            vt_color C_BODY, C_BG
            vt_print Space(HLP_IDX_W)
            Continue For
        End If

        If ilst(ei).is_grp Then
            ' Group header: white on black, full pane width
            vt_color C_GRP, C_BG
            vt_print Left(ilst(ei).disp & Space(HLP_IDX_W), HLP_IDX_W)
        Else
            ' Topic entry
            Dim is_sel As Byte = (ilst(ei).tidx = cur_top)
            Dim pfx    As String
            If is_sel Then
                pfx = "> "
                If cur_pane = 0 Then
                    vt_color C_SEL_F, C_SEL_B     ' active pane: bright selection
                Else
                    vt_color C_DSEL_F, C_DSEL_B   ' inactive pane: dim selection
                End If
            Else
                pfx = "  "
                vt_color C_BODY, C_BG
            End If
            vt_print Left(pfx & ilst(ei).disp & Space(HLP_IDX_W), HLP_IDX_W)
        End If
    Next
End Sub

Sub draw_content()
    Dim rr As Long
    For rr = 0 To HLP_PNL_H - 1
        Dim li  As Long = top_ln + rr
        Dim row As Long = HLP_PNL_T + rr
        vt_locate row, HLP_CNT_C

        If li < 0 Or li >= nrlines Then
            vt_color C_BODY, C_BG
            vt_print Space(HLP_CNT_W)
            Continue For
        End If

        ' Check whether a keyboard-focused link sits on this line
        Dim frow As Byte = 0
        Dim fcs  As Long = 0, fce As Long = 0
        If focus_lnk >= 0 And focus_lnk < nlnks And cur_pane = 1 Then
            If lnks(focus_lnk).ridx = li Then
                frow = 1 : fcs = lnks(focus_lnk).cs : fce = lnks(focus_lnk).ce
            End If
        End If

        If li = 0 Then
            ' Topic title -- first render line, always line index 0
            vt_color C_TITLE, C_BG
            vt_print Left(" " & rlines(li).txt & Space(HLP_CNT_W), HLP_CNT_W)

        ElseIf rlines(li).is_head Then
            ' Section header (already HLP_CNT_W chars from renderer)
            vt_color C_SEC, C_BG
            vt_print Left(rlines(li).txt & Space(HLP_CNT_W), HLP_CNT_W)

        ElseIf rlines(li).is_code Then
            ' Verbatim code line
            vt_color C_CODE, C_BG
            vt_print Left(" " & rlines(li).txt & Space(HLP_CNT_W), HLP_CNT_W)

        ElseIf rlines(li).is_link Then
            ' See-also link entry
            vt_color C_LINK, C_BG
            vt_print Left(" " & rlines(li).txt & Space(HLP_CNT_W), HLP_CNT_W)
            ' Overdraw focused link name with highlight color
            If frow Then
                Dim lnm As String = Mid(rlines(li).txt, fcs, fce - fcs + 1)
                vt_color C_LKHI_F, C_LKHI_B
                ' Screen col of txt[fcs]: HLP_CNT_C + fcs  (because we prefix " ")
                vt_locate row, HLP_CNT_C + fcs
                vt_print lnm
            End If

        Else
            ' Normal body text
            vt_color C_BODY, C_BG
            vt_print Left(" " & rlines(li).txt & Space(HLP_CNT_W), HLP_CNT_W)
        End If
    Next
End Sub

' ============================================================
' Mouse click handler
' ============================================================
Sub handle_click(mx As Long, my As Long)
    If my < HLP_PNL_T Or my > HLP_PNL_B Then Exit Sub
    Dim roff As Long = my - HLP_PNL_T

    If mx >= 1 And mx <= HLP_IDX_W Then
        ' ---- Index pane click ----
        cur_pane = 0
        Dim ei As Long = idx_top + roff
        If ei >= 0 And ei < nilst Then
            If ilst(ei).is_grp = 0 Then
                idx_sel = ei
                hlp_navigate ilst(ei).tidx
                'cur_pane = 1
            End If
        End If

    ElseIf mx >= HLP_CNT_C And mx <= HLP_COLS Then
        ' ---- Content pane click ----
        cur_pane = 1
        ' Hit-test against visible links
        Dim li As Long
        For li = 0 To nlnks - 1
            ' Screen row of this link
            Dim lscr As Long = HLP_PNL_T + (lnks(li).ridx - top_ln)
            If lscr < HLP_PNL_T Or lscr > HLP_PNL_B Then Continue For
            If lscr <> my Then Continue For
            ' Column range: HLP_CNT_C + col_start .. HLP_CNT_C + col_end
            ' (because draw_content prints " " & txt at HLP_CNT_C)
            Dim scs As Long = HLP_CNT_C + lnks(li).cs
            Dim sce As Long = HLP_CNT_C + lnks(li).ce
            If mx >= scs And mx <= sce Then
                Dim tgt_i As Long = find_topic_n(lnks(li).tgt)
                If tgt_i >= 0 Then hlp_navigate tgt_i
                Exit For
            End If
        Next
    End If
End Sub

' ============================================================
' Entry point
' ============================================================
Dim hlp_arg As String = Command(1)
If hlp_arg = "" Then
    ' Try the default VT API help file
    If Dir("vt.vth") <> "" Then
        hlp_arg = "vt.vth"
    Else
        Print "Usage: vthelp <file.vth>"
        Print "       Loads vt.vth from current directory when no argument given."
        End 1
    End If
End If

hlp_disp = path_base(hlp_arg)
hlp_load hlp_arg

If ntopics = 0 Then
    Print "vthelp: no topics found in '" & hlp_arg & "'"
    End 1
End If

build_ilst

ReDim bstk(HLP_BACK_M - 1) As hlp_bentry
bstk_d = 0

' --- Initialise VT ---
vt_title "VTHELP"
If vt_screen(VT_SCREEN_12, VT_WINDOWED ) <> 0 Then
    Print "vthelp: vt_screen failed"
    End 1
End If
vt_mouse 1
vt_copypaste VT_ENABLED
vt_locate ,,0    ' hide cursor; vthelp draws its own selection
vt_scroll_enable(VT_DISABLED)

' Navigate to the first topic without creating a back-stack entry
cur_pane = 0
idx_top  = 0
idx_sel  = 0
hlp_goto 0

' ============================================================
' Main event loop
' ============================================================
Dim kk   As ULong
Dim mx   As Long, my As Long, mb As Long, mw As Long
Dim pmb  As Long = 0     ' previous mouse button state (for edge detection)

Do
    kk = vt_inkey()
    vt_getmouse @mx, @my, @mb, @mw

    ' --- Mouse wheel: scroll active pane ---
    If mw <> 0 Then
        If cur_pane = 0 Then
            scroll_idx -mw * 3
        Else
            scroll_cnt -mw * 3
        End If
    End If

    ' --- Mouse left-click (rising edge) ---
    If (mb And VT_MOUSE_BTN_LEFT) <> 0 And (pmb And VT_MOUSE_BTN_LEFT) = 0 Then
        handle_click mx, my
    End If
    pmb = mb

    ' --- Keyboard ---
    If kk <> 0 Then
        Select Case VT_SCAN(kk)
        Case VT_KEY_ESC
            If bstk_d > 0 Then
                hlp_back
            Else
                Beep
            End If

        Case VT_KEY_F1
            ' Jump to index pane, highlight first topic
            cur_pane = 0
            Dim fi As Long = 0
            Do While fi < nilst And ilst(fi).is_grp : fi += 1 : Loop
            If fi < nilst Then
                idx_sel = fi
                If idx_sel < idx_top Then idx_top = idx_sel
                If idx_sel >= idx_top + HLP_PNL_H Then idx_top = idx_sel - HLP_PNL_H + 1
            End If

        Case VT_KEY_F2
            ' Jump to content pane
            cur_pane = 1

        Case VT_KEY_TAB
            If cur_pane = 0 Then
                ' Tab from index: move focus to content pane (like F2)
                cur_pane = 1
            ElseIf nlnks > 0 Then
                ' Tab / Shift+Tab in content: cycle through links
                If VT_SHIFT(kk) Then
                    focus_lnk -= 1
                    If focus_lnk < 0 Then focus_lnk = nlnks - 1
                Else
                    focus_lnk += 1
                    If focus_lnk >= nlnks Then focus_lnk = 0
                End If
                lnk_ensure_visible focus_lnk
            End If

        Case VT_KEY_UP
            If cur_pane = 0 Then idx_move -1 Else scroll_cnt -1

        Case VT_KEY_DOWN
            If cur_pane = 0 Then idx_move 1 Else scroll_cnt 1

        Case VT_KEY_PGUP
            If cur_pane = 0 Then scroll_idx -HLP_PNL_H Else scroll_cnt -HLP_PNL_H

        Case VT_KEY_PGDN
            If cur_pane = 0 Then scroll_idx HLP_PNL_H Else scroll_cnt HLP_PNL_H

        Case VT_KEY_HOME
            If cur_pane = 0 Then idx_top = 0 Else top_ln = 0

        Case VT_KEY_END
            If cur_pane = 0 Then scroll_idx nilst Else scroll_cnt nrlines

        Case VT_KEY_ENTER
            If cur_pane = 0 Then
                If idx_sel >= 0 And idx_sel < nilst Then
                    If ilst(idx_sel).is_grp = 0 Then
                        hlp_navigate ilst(idx_sel).tidx
                        cur_pane = 1
                    End If
                End If
            Else
                ' Content pane Enter: follow the focused link
                If focus_lnk >= 0 And focus_lnk < nlnks Then
                    Dim tgt_i As Long = find_topic_n(lnks(focus_lnk).tgt)
                    If tgt_i >= 0 Then hlp_navigate tgt_i
                End If
            End If
        End Select
    End If

    ' --- Draw frame ---
    vt_view_print
        
    vt_color C_BODY, C_BG
    vt_cls

    draw_chrome
    draw_index
    draw_content

    ' Leave viewport set to active pane - mouse copy-paste inherits it
    If cur_pane = 0 Then
        vt_view_print HLP_PNL_T, HLP_PNL_B, 1, HLP_IDX_W
    Else
        vt_view_print HLP_PNL_T, HLP_PNL_B, HLP_CNT_C, HLP_COLS
    End If

    vt_sleep 25
Loop

vt_shutdown
