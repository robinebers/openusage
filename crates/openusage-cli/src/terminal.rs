use std::io;

/// Item for the multi-select picker
#[derive(Debug, Clone)]
pub struct PickerItem {
    pub id: String,
    pub label: String,
    pub selected: bool,
}

/// Abstraction over terminal I/O for testability
pub trait Terminal {
    /// Display a multi-select picker. Returns the IDs of selected items.
    /// User navigates with arrow keys, toggles with space, confirms with enter.
    fn picker(&mut self, title: &str, items: Vec<PickerItem>) -> io::Result<Vec<String>>;

    /// Prompt for yes/no confirmation. Returns true for yes.
    /// `default_yes` controls what happens when user just hits enter.
    fn confirm(&mut self, message: &str, default_yes: bool) -> io::Result<bool>;

    /// Prompt for text input. Returns the entered string (may be empty).
    fn input(&mut self, prompt: &str, default: Option<&str>) -> io::Result<String>;

    /// Display a message and wait for Enter key.
    fn wait_for_enter(&mut self, message: &str) -> io::Result<()>;

    /// Print a line to the terminal.
    fn println(&mut self, message: &str);

    /// Print a line to the terminal without newline.
    fn print(&mut self, message: &str);
}

// ---------------------------------------------------------------------------
// CrosstermTerminal — real implementation using crossterm
// ---------------------------------------------------------------------------

use crossterm::{
    cursor,
    event::{self, Event, KeyCode, KeyEvent, KeyModifiers},
    execute,
    terminal::{self as ct, ClearType},
    style::Print,
};

pub struct CrosstermTerminal;

impl CrosstermTerminal {
    pub fn new() -> Self {
        Self
    }

    /// Render the picker UI to the terminal (no alternate screen — just redraws in place).
    fn render_picker(
        &self,
        stdout: &mut io::Stdout,
        title: &str,
        items: &[PickerItem],
        cursor_pos: usize,
    ) -> io::Result<()> {
        // Move cursor to top-left of our drawing area and clear down
        execute!(
            stdout,
            cursor::MoveToColumn(0),
        )?;

        // Title
        execute!(stdout, Print(title), Print("\r\n"))?;
        execute!(stdout, Print("\r\n"))?;

        for (i, item) in items.iter().enumerate() {
            let prefix = if i == cursor_pos { "> " } else { "  " };
            let check = if item.selected { "[x]" } else { "[ ]" };
            execute!(
                stdout,
                ct::Clear(ClearType::CurrentLine),
                Print(format!("{prefix}{check} {}\r\n", item.label))
            )?;
        }

        execute!(stdout, Print("\r\n"))?;
        execute!(
            stdout,
            ct::Clear(ClearType::CurrentLine),
            Print("  \u{2191}\u{2193} navigate  SPACE toggle  ENTER confirm\r\n")
        )?;

        Ok(())
    }
}

impl Terminal for CrosstermTerminal {
    fn picker(&mut self, title: &str, items: Vec<PickerItem>) -> io::Result<Vec<String>> {
        use std::io::Write;

        if items.is_empty() {
            return Ok(vec![]);
        }

        let mut items = items;
        let mut cursor_pos: usize = 0;
        let mut stdout = io::stdout();

        ct::enable_raw_mode()?;

        // Initial render
        self.render_picker(&mut stdout, title, &items, cursor_pos)?;
        stdout.flush()?;

        loop {
            if let Event::Key(KeyEvent { code, modifiers, .. }) = event::read()? {
                // Ctrl+C exits with empty selection
                if modifiers.contains(KeyModifiers::CONTROL) && code == KeyCode::Char('c') {
                    ct::disable_raw_mode()?;
                    return Ok(vec![]);
                }

                match code {
                    KeyCode::Up => {
                        if cursor_pos == 0 {
                            cursor_pos = items.len() - 1;
                        } else {
                            cursor_pos -= 1;
                        }
                    }
                    KeyCode::Down => {
                        cursor_pos = (cursor_pos + 1) % items.len();
                    }
                    KeyCode::Char(' ') => {
                        items[cursor_pos].selected = !items[cursor_pos].selected;
                    }
                    KeyCode::Enter => {
                        ct::disable_raw_mode()?;
                        // Print final newline
                        execute!(stdout, Print("\r\n"))?;
                        let selected: Vec<String> = items
                            .iter()
                            .filter(|it| it.selected)
                            .map(|it| it.id.clone())
                            .collect();
                        return Ok(selected);
                    }
                    _ => {}
                }

                // Move cursor back up to redraw
                let lines_drawn = items.len() + 4; // title + blank + items + blank + hint
                execute!(stdout, cursor::MoveUp(lines_drawn as u16))?;
                self.render_picker(&mut stdout, title, &items, cursor_pos)?;
                stdout.flush()?;
            }
        }
    }

    fn confirm(&mut self, message: &str, default_yes: bool) -> io::Result<bool> {
        use std::io::Write;

        let hint = if default_yes { "[Y/n]" } else { "[y/N]" };
        let mut stdout = io::stdout();

        ct::enable_raw_mode()?;
        execute!(stdout, Print(format!("{message} {hint} ")))?;
        stdout.flush()?;

        let result = loop {
            if let Event::Key(KeyEvent { code, modifiers, .. }) = event::read()? {
                if modifiers.contains(KeyModifiers::CONTROL) && code == KeyCode::Char('c') {
                    break false;
                }
                match code {
                    KeyCode::Char('y') | KeyCode::Char('Y') => break true,
                    KeyCode::Char('n') | KeyCode::Char('N') => break false,
                    KeyCode::Enter => break default_yes,
                    _ => {}
                }
            }
        };

        ct::disable_raw_mode()?;
        execute!(stdout, Print("\r\n"))?;
        Ok(result)
    }

    fn input(&mut self, prompt: &str, default: Option<&str>) -> io::Result<String> {
        use std::io::{BufRead, Write};

        let mut stdout = io::stdout();
        if let Some(def) = default {
            write!(stdout, "{prompt} ({def}): ")?;
        } else {
            write!(stdout, "{prompt}: ")?;
        }
        stdout.flush()?;

        let mut line = String::new();
        io::stdin().lock().read_line(&mut line)?;
        let line = line.trim_end_matches('\n').trim_end_matches('\r').to_string();
        Ok(line)
    }

    fn wait_for_enter(&mut self, message: &str) -> io::Result<()> {
        use std::io::{BufRead, Write};

        let mut stdout = io::stdout();
        write!(stdout, "{message}")?;
        stdout.flush()?;

        let mut buf = String::new();
        io::stdin().lock().read_line(&mut buf)?;
        Ok(())
    }

    fn println(&mut self, message: &str) {
        println!("{message}");
    }

    fn print(&mut self, message: &str) {
        use std::io::Write;
        print!("{message}");
        let _ = io::stdout().flush();
    }
}

// ---------------------------------------------------------------------------
// MockTerminal — for testing
// ---------------------------------------------------------------------------

pub struct MockTerminal {
    picker_responses: Vec<Vec<String>>,
    confirm_responses: Vec<bool>,
    input_responses: Vec<String>,
    wait_count: usize,
    printed: Vec<String>,
    picker_call_count: usize,
    confirm_call_count: usize,
    input_call_count: usize,
}

impl MockTerminal {
    pub fn new() -> Self {
        Self {
            picker_responses: Vec::new(),
            confirm_responses: Vec::new(),
            input_responses: Vec::new(),
            wait_count: 0,
            printed: Vec::new(),
            picker_call_count: 0,
            confirm_call_count: 0,
            input_call_count: 0,
        }
    }

    pub fn with_picker_responses(mut self, responses: Vec<Vec<String>>) -> Self {
        self.picker_responses = responses;
        self
    }

    pub fn with_confirm_responses(mut self, responses: Vec<bool>) -> Self {
        self.confirm_responses = responses;
        self
    }

    pub fn with_input_responses(mut self, responses: Vec<String>) -> Self {
        self.input_responses = responses;
        self
    }

    pub fn wait_count(&self) -> usize {
        self.wait_count
    }

    pub fn printed(&self) -> &[String] {
        &self.printed
    }
}

impl Terminal for MockTerminal {
    fn picker(&mut self, _title: &str, _items: Vec<PickerItem>) -> io::Result<Vec<String>> {
        let result = if self.picker_call_count < self.picker_responses.len() {
            self.picker_responses[self.picker_call_count].clone()
        } else {
            vec![]
        };
        self.picker_call_count += 1;
        Ok(result)
    }

    fn confirm(&mut self, _message: &str, _default_yes: bool) -> io::Result<bool> {
        let result = if self.confirm_call_count < self.confirm_responses.len() {
            self.confirm_responses[self.confirm_call_count]
        } else {
            false
        };
        self.confirm_call_count += 1;
        Ok(result)
    }

    fn input(&mut self, _prompt: &str, _default: Option<&str>) -> io::Result<String> {
        let result = if self.input_call_count < self.input_responses.len() {
            self.input_responses[self.input_call_count].clone()
        } else {
            String::new()
        };
        self.input_call_count += 1;
        Ok(result)
    }

    fn wait_for_enter(&mut self, _message: &str) -> io::Result<()> {
        self.wait_count += 1;
        Ok(())
    }

    fn println(&mut self, message: &str) {
        self.printed.push(message.to_string());
    }

    fn print(&mut self, message: &str) {
        self.printed.push(message.to_string());
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mock_picker_returns_scripted_responses() {
        let mut term = MockTerminal::new().with_picker_responses(vec![
            vec!["github".to_string(), "openai".to_string()],
            vec!["cursor".to_string()],
        ]);

        let items = vec![
            PickerItem { id: "github".into(), label: "GitHub Copilot".into(), selected: false },
            PickerItem { id: "openai".into(), label: "OpenAI".into(), selected: false },
        ];

        let result1 = term.picker("Pick providers", items.clone()).unwrap();
        assert_eq!(result1, vec!["github", "openai"]);

        let result2 = term.picker("Pick again", items).unwrap();
        assert_eq!(result2, vec!["cursor"]);
    }

    #[test]
    fn mock_confirm_returns_scripted_responses() {
        let mut term = MockTerminal::new().with_confirm_responses(vec![true, false, true]);

        assert!(term.confirm("Continue?", false).unwrap());
        assert!(!term.confirm("Sure?", true).unwrap());
        assert!(term.confirm("Really?", false).unwrap());
    }

    #[test]
    fn mock_input_returns_scripted_responses() {
        let mut term = MockTerminal::new().with_input_responses(vec![
            "hello".to_string(),
            "world".to_string(),
        ]);

        assert_eq!(term.input("Name", None).unwrap(), "hello");
        assert_eq!(term.input("Other", Some("default")).unwrap(), "world");
    }

    #[test]
    fn mock_wait_for_enter_increments_count() {
        let mut term = MockTerminal::new();
        assert_eq!(term.wait_count(), 0);

        term.wait_for_enter("Press enter...").unwrap();
        assert_eq!(term.wait_count(), 1);

        term.wait_for_enter("Again...").unwrap();
        term.wait_for_enter("Once more...").unwrap();
        assert_eq!(term.wait_count(), 3);
    }

    #[test]
    fn mock_println_captures_output() {
        let mut term = MockTerminal::new();

        term.println("Hello world");
        term.println("Second line");
        term.print("no newline");

        assert_eq!(term.printed(), &["Hello world", "Second line", "no newline"]);
    }

    #[test]
    fn mock_empty_queue_returns_defaults() {
        let mut term = MockTerminal::new();

        // Empty picker queue returns empty vec
        let picker_result = term.picker("title", vec![]).unwrap();
        assert!(picker_result.is_empty());

        // Empty confirm queue returns false
        let confirm_result = term.confirm("ok?", true).unwrap();
        assert!(!confirm_result);

        // Empty input queue returns empty string
        let input_result = term.input("name", None).unwrap();
        assert!(input_result.is_empty());
    }
}
