import datetime

# A very lightweight logger.
# It does not depend on Python's standard `logging` module; instead it just
# appends strings to a file under `test/logs/`. The advantage is that it stays
# simple, and test scripts can later re-open the same log file to do regex
# matching against captured output.
class Logger:
    def __init__(self, level="debug"):
        # Use the current time to build the log filename so each test run
        # produces a fresh file instead of overwriting the previous one.
        self.filename = f"test/logs/log_{datetime.datetime.now().strftime('%Y%m%d%H%M%S')}.txt"
        self.level = level

    def debug(self, *messages):
        # `*messages` is a varargs parameter, so callers can pass any number of
        # message fragments in a single call.
        if self.level == "debug":
            self.info(*messages)

    def info(self, *messages):
        # Convert every argument to a string first, then join them with spaces
        # to form a single line.
        full_message = ' '.join(str(message) for message in messages)
        # Open the file in append mode so each write goes at the end.
        with open(self.filename, "a") as log_file:
            log_file.write(full_message + "\n")


# Module-level singleton: other files do `from .logger import logger` and share
# this one instance.
logger = Logger(level="debug")
