// Wave 1 foundations: diagnostics model + deterministic rendering.

use Span
use Source
use DiagnosticRender

extern fn with_eprint(s: str) -> Unit
extern fn with_str_clone(s: str) -> str

enum DiagSeverity: i32:
    Error = 1
    Warning = 2
    Note = 3

// Legacy aliases kept for existing callers.
const SEV_ERROR: i32 = DiagSeverity.Error
const SEV_WARNING: i32 = DiagSeverity.Warning

type DiagnosticLabel {
    span: Span,
    message: str,
}

// Legacy alias kept for existing callers.
type Label = DiagnosticLabel

type Diagnostic {
    severity: i32,
    code: str,
    message: str,
    origin_file: str,
    origin_fn: str,
    origin_line: i32,
    origin_node: i32,
    primary: Span,
    labels: Vec[DiagnosticLabel],
    notes: Vec[str],
    helps: Vec[str],
}

fn diagnostic_owned_text(text: str) -> str:
    with_str_clone(text)

fn diagnostic_error(message: str, primary: Span) -> Diagnostic:
    Diagnostic {
        severity: DiagSeverity.Error,
        code: "",
        message: diagnostic_owned_text(message),
        origin_file: "",
        origin_fn: "",
        origin_line: 0,
        origin_node: 0,
        primary,
        labels: Vec.new(),
        notes: Vec.new(),
        helps: Vec.new(),
    }

fn diagnostic_warning(message: str, primary: Span) -> Diagnostic:
    Diagnostic {
        severity: DiagSeverity.Warning,
        code: "",
        message: diagnostic_owned_text(message),
        origin_file: "",
        origin_fn: "",
        origin_line: 0,
        origin_node: 0,
        primary,
        labels: Vec.new(),
        notes: Vec.new(),
        helps: Vec.new(),
    }

fn Diagnostic.err(message: str, span: Span) -> Diagnostic:
    diagnostic_error(message, span)

fn Diagnostic.warn(message: str, span: Span) -> Diagnostic:
    diagnostic_warning(message, span)

impl Diagnostic:
    mut fn set_code(code: str):
        self.code = diagnostic_owned_text(code)

    mut fn set_origin(file: str, fn_name: str, line: i32, node: i32):
        self.origin_file = diagnostic_owned_text(file)
        self.origin_fn = diagnostic_owned_text(fn_name)
        self.origin_line = line
        self.origin_node = node

    mut fn add_label(span: Span, message: str) -> Unit:
        self.labels.push(DiagnosticLabel { span, message: diagnostic_owned_text(message) })

    mut fn add_note(message: str) -> Unit:
        self.notes.push(diagnostic_owned_text(message))

    mut fn add_help(message: str) -> Unit:
        self.helps.push(diagnostic_owned_text(message))

    fn render(source: Source):
        let code: str = self.code
        let message: str = self.message
        with_eprint(render_diag_header(self.severity, code, message))

        let loc = source.offset_to_location(self.primary.start)
        let source_path: str = source.path
        with_eprint(render_diag_location(source_path, loc.line, loc.col))

        let line_text: str = source.line_text(loc.line)
        with_eprint(render_diag_source_line(loc.line, line_text))
        with_eprint(render_diag_marker_line(loc.col, span_underline_len(self.primary.start, self.primary.end)))

        for i in 0..self.labels.len() as i32:
            let lab: DiagnosticLabel = self.labels.get(i as i64)
            let lloc = source.offset_to_location(lab.span.start)
            let label_message: str = lab.message
            with_eprint(render_diag_label_line(lloc.line, lloc.col, label_message))

        for i in 0..self.notes.len() as i32:
            let note: str = self.notes.get(i as i64)
            with_eprint(render_diag_note_line(note))
        for i in 0..self.helps.len() as i32:
            let help: str = self.helps.get(i as i64)
            with_eprint(render_diag_help_line(help))

pub type DiagnosticList {
    items: Vec[Diagnostic],
}

fn DiagnosticList.init -> DiagnosticList:
    DiagnosticList {
        items: Vec.new(),
    }

// No-op: reserved for future manual memory management.
impl DiagnosticList:
    fn deinit():
        return

    mut fn emit(diag: Diagnostic) -> Unit:
        self.items.push(diag)

    fn count() -> i32:
        self.items.len() as i32

    fn count_by_severity(severity: i32) -> i32:
        var n = 0
        for i in 0..self.items.len() as i32:
            if self.items.get(i as i64).severity == severity:
                n = n + 1
        n

    fn has_errors() -> bool:
        self.count_by_severity(DiagSeverity.Error) > 0

    fn render_all(source: Source):
        for i in 0..self.items.len() as i32:
            self.items.get(i as i64).render(source)
            if i + 1 < self.items.len() as i32:
                with_eprint("")

    fn render_warnings(source: Source):
        var printed = 0
        for i in 0..self.items.len() as i32:
            if self.items.get(i as i64).severity != DiagSeverity.Warning:
                continue
            if printed != 0:
                with_eprint("")
            self.items.get(i as i64).render(source)
            printed = printed + 1
