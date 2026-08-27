use std::env;
use std::io::{self, Write};
use std::process::ExitCode;

use omarchy_vscode_projects::{clear_pins, list_payload, set_pin, write_payload_to};

#[derive(Clone, Copy, PartialEq, Eq)]
enum Action {
    List,
    Pin,
    Unpin,
    UnpinAll,
}

struct Args {
    action: Action,
    limit: i32,
    path: Option<String>,
    editor: String,
    kind: String,
}

fn usage() -> &'static str {
    "Usage: vsc-recent-projects [list|pin|unpin|unpin-all] [--limit N] [--path PATH] [--editor COMMAND] [--kind KIND]"
}

fn next_value<I>(arguments: &mut I, option: &str) -> Result<String, String>
where
    I: Iterator<Item = String>,
{
    arguments
        .next()
        .ok_or_else(|| format!("{option} requires a value"))
}

fn parse_args() -> Result<Option<Args>, String> {
    let mut arguments = env::args().skip(1).peekable();
    let mut action = Action::List;
    if let Some(first) = arguments.peek() {
        action = match first.as_str() {
            "list" => Action::List,
            "pin" => Action::Pin,
            "unpin" => Action::Unpin,
            "unpin-all" => Action::UnpinAll,
            "-h" | "--help" => return Ok(None),
            value if value.starts_with('-') => Action::List,
            value => return Err(format!("unknown action: {value}")),
        };
        if !first.starts_with('-') {
            arguments.next();
        }
    }

    let mut parsed = Args {
        action,
        limit: 10,
        path: None,
        editor: "code".to_owned(),
        kind: "folder".to_owned(),
    };
    while let Some(argument) = arguments.next() {
        match argument.as_str() {
            "--limit" => {
                let value = next_value(&mut arguments, "--limit")?;
                parsed.limit = value
                    .parse()
                    .map_err(|_| format!("invalid --limit value: {value}"))?;
            }
            "--path" => parsed.path = Some(next_value(&mut arguments, "--path")?),
            "--editor" => parsed.editor = next_value(&mut arguments, "--editor")?,
            "--kind" => parsed.kind = next_value(&mut arguments, "--kind")?,
            "-h" | "--help" => return Ok(None),
            value => return Err(format!("unknown option: {value}")),
        }
    }
    if matches!(parsed.action, Action::Pin | Action::Unpin) && parsed.path.is_none() {
        return Err("--path is required for pin and unpin".to_owned());
    }
    Ok(Some(parsed))
}

fn run(args: Args) -> Result<(), String> {
    match args.action {
        Action::UnpinAll => clear_pins().map_err(|error| error.to_string()),
        Action::Pin | Action::Unpin => set_pin(
            args.path.as_deref().expect("validated by parse_args"),
            &args.editor,
            &args.kind,
            args.action == Action::Pin,
        )
        .map_err(|error| error.to_string()),
        Action::List => {
            let payload = list_payload(args.limit.clamp(1, 100) as usize);
            let stdout = io::stdout();
            let mut output = stdout.lock();
            match write_payload_to(&mut output, &payload).map_err(|error| error.to_string())? {
                true => Ok(()),
                false => Err("recent projects output exceeded limit".to_owned()),
            }
        }
    }
}

fn main() -> ExitCode {
    let args = match parse_args() {
        Ok(Some(args)) => args,
        Ok(None) => {
            println!("{}", usage());
            return ExitCode::SUCCESS;
        }
        Err(error) => {
            let _ = writeln!(io::stderr(), "vsc-recent-projects: {error}\n{}", usage());
            return ExitCode::from(2);
        }
    };
    match run(args) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            let _ = writeln!(io::stderr(), "vsc-recent-projects: {error}");
            ExitCode::FAILURE
        }
    }
}
