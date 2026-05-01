;; -*- mode: eask; lexical-binding: t -*-

(package "pending"
         "0.2.0"
         "Async pending content placeholders")

(author "John Wiegley" "jwiegley@gmail.com")
(license "BSD-3-Clause")
(website-url "https://github.com/jwiegley/pending")
(keywords "convenience" "tools")

(package-file "pending.el")

(files "pending.el"
       "pending-aio.el"
       "doc/pending.info"
       "doc/pending.texi"
       "README.md"
       "LICENSE.md")

(script "test" "eask test ert pending-test.el pending-aio-test.el")
(script "test-aio" "eask test ert pending-aio-test.el")

(source "gnu")
(source "melpa")

(depends-on "emacs" "27.1")

(development
 (depends-on "package-lint")
 (depends-on "undercover")
 (depends-on "aio"))
