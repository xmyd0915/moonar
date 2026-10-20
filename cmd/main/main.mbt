///|
fn main {
  let arguments = @env.args()
  let request = match
    @cli.parse_args(arguments[cli_argument_start():].to_owned()) {
    Ok(request) => request
    Err(message) => {
      eprintln(message)
      @sys.exit(2)
      return
    }
  }
  let result = @cli.run(
    request,
    fn(path) {
      Ok(@fs.read_file_to_bytes(path)) catch {
        @fs.IOError(message) => Err(message)
      }
    },
    write=atomic_write,
    validate_path=check_member_path,
    canonical=canonical_path,
  )
  if !result.stdout.is_empty() {
    println(result.stdout[:result.stdout.length() - 1].to_owned())
  }
  if !result.stderr.is_empty() {
    eprintln(result.stderr[:result.stderr.length() - 1].to_owned())
  }
  @sys.exit(result.exit_code)
}
