;;; hyperdrive-org.el --- Org-transclusion-related functionality  -*- lexical-binding: t; -*-

;; Copyright (C) 2024  USHIN, Inc.

;; Author: Joseph Turner <joseph@ushin.org>
;; Author: Adam Porter <adam@alphapapa.net>
;; Maintainer: Joseph Turner <~ushin/ushin@lists.sr.ht>
;; Created: 2024
;; Version: 0.1-pre
;; Package-Requires: ((emacs "28.1") (hyperdrive "0.4") (org-transclusion "1.4.0"))
;; Homepage: https://git.sr.ht/~ushin/hyperdrive-org-transclusion

;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU Affero General Public License
;; as published by the Free Software Foundation, either version 3 of
;; the License, or (at your option) any later version.

;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
;; Affero General Public License for more details.

;; You should have received a copy of the GNU Affero General Public
;; License along with this program. If not, see
;; <https://www.gnu.org/licenses/>.

;;; Commentary:

;; This file contains functionality related to transcluding content over the
;; hyper:// protocol using hyperdrive.el.  Features include:
;;
;; - Transclude plain text
;;   + Transclude only Org headings matching search options
;; - Transclude HTML converted to Org using Pandoc with `org-transclusion-html'
;;   + Transclude only HTML headings matching link anchor
;; - TODO: Support :lines
;; - TODO: Handle relative links in transcluded content.

;;; Code:

;;;; Check org-transclusion version v1.4.0 or later

;;;; Requirements

(require 'cl-lib)
(require 'org)
(require 'org-element)

(require 'hyperdrive)

(require 'find-func)
(require 'lisp-mnt)

;;;###autoload
(with-eval-after-load 'org-transclusion
  (if-let ((library-name (ignore-errors (find-library-name "org-transclusion")))
           (org-transclusion-version
            (with-temp-buffer
              (insert-file-contents library-name)
              (lm-version)))
           ((version< org-transclusion-version "1.4.0")))
      (warn "hyperdrive-org-transclusion:  Upgrade org-transclusion in order to transclude hyperdrive content.")

    (require 'hyperdrive-org)
    (require 'org-transclusion-html)

;;;; Functions

    (defun hyperdrive-org-transclusion-add (link _plist)
      "Handle hyperdrive transclusion.
Return `hyperdrive-org-transclusion-add-file' when
transclusion link is a hyperdrive link.  Otherwise, return nil.
Intended to be added to `org-transclusion-add-functions', which
see for descriptions of arguments LINK and PLIST."
      (declare-function hyperdrive-org-transclusion-add-file
                        "hyperdrive-org-transclusion")
      (and (or (string= "hyper" (org-element-property :type link))
               (and hyperdrive-mode
                    (hyperdrive-org--element-entry link)))
           (hyperdrive-message "Asynchronously transcluding hyperdrive file at point %d, line %d..."
                               (point) (org-current-line))
           #'hyperdrive-org-transclusion-add-file))

    (declare-function hyperdrive-org-transclusion-add "hyperdrive-org-transclusion")
    (add-hook 'org-transclusion-add-functions #'hyperdrive-org-transclusion-add)

    (defun hyperdrive-org-transclusion-add-file (link plist copy)
      "Load hyperdrive file at LINK.
Then call `org-transclusion-add-payload' with PAYLOAD, LINK,
PLIST, COPY."
      (declare-function hyperdrive-org-transclusion-error-handler
                        "hyperdrive-org-transclusion")
      (declare-function org-transclusion-org-file-p "org-transclusion")
      (declare-function org-transclusion-add-payload "org-transclusion")
      (declare-function org-transclusion-content-org-buffer-or-element
                        "org-transclusion")
      (declare-function org-transclusion-html--html-p "org-transclusion-html")
      (declare-function org-transclusion-html--target-content
                        "org-transclusion-html")
      (declare-function org-transclusion--insert-org-from-html-with-pandoc
                        "org-transclusion-html")
      (pcase-let* ((target-mkr (point-marker))
                   (raw-link (org-element-property :raw-link link))
                   (entry (if (string= "hyper" (org-element-property :type link))
                              ;; Absolute link
                              (hyperdrive-url-entry raw-link)
                            ;; Relative link
                            (hyperdrive-org--element-entry link)))
                   ((cl-struct hyperdrive-entry hyperdrive path etc) entry)
                   ((map target) etc)
                   (tc-type))
        (when (hyperdrive--entry-directory-p entry)
          (user-error "hyperdrive-org-transclusion:  Directory transclusion not supported: <%s>"
                      raw-link))
        ;; Use `hyperdrive-fill' with callback instead of `hyperdrive-open':

        ;; - Transclusion source buffers should be different from hyperdrive-mode
        ;; buffers visiting the same hyperdrive file.  Transclusion source buffers
        ;; may be modified/narrowed according to transclude: link parameters, and
        ;; the hyperdrive-mode buffers should be unaffected by transclusions.

        ;; - Errors (e.g. file not found, no matching org search option) shouldn't
        ;; result in user interaction.

        ;; - Even if `hyperdrive-render-html' is non-nil, the callback needs raw
        ;; HTML so it can call `org-transclusion--insert-org-from-html-with-pandoc'.

        ;; - Avoid unnecessarily loading major mode based on content type.
        (hyperdrive-fill entry
          :then
          (lambda (entry)
            (hyperdrive-fill-latest-version hyperdrive)
            (hyperdrive-persist hyperdrive)
            (hyperdrive-api 'get (hyperdrive-entry-url entry) :noquery t :as 'buffer
              :then
              (lambda (_buffer)
                (when-let ((target-buf (marker-buffer target-mkr)))
                  (cond ((org-transclusion-html--html-p (current-buffer)) ; HTML
                         (let ((dom (libxml-parse-html-region)))
                           (when (dom-by-id dom (format "\\`%s\\'" target))
                             ;; Page contains id element matching link target.
                             (erase-buffer)
                             (dom-print
                              (org-transclusion-html--target-content dom target)))
                           (org-transclusion--insert-org-from-html-with-pandoc)
                           ;; Use "org"-prefixed `tc-type' since HTML is converted
                           ;; to Org mode.
                           (setf tc-type "org-html-hyper")))
                        ((org-transclusion-org-file-p path) ; Org-mode
                         (when target
                           (org-mode)
                           (let ((org-link-search-must-match-exact-headline t))
                             (when (with-demoted-errors "hyperdrive-org-transclusion error:\n%s\ntranscluding whole file..."
                                     (org-link-search (format "%s" target)))
                               (org-narrow-to-subtree))))
                         (setf tc-type "org-hyper"))
                        (t   ; All other file types
                         (setf tc-type "others-hyper")))
                  (let* ((payload-without-type
                          (org-transclusion-content-org-buffer-or-element
                           nil plist))
                         (payload
                          (append `(:tc-type ,tc-type) payload-without-type)))
                    (with-current-buffer target-buf
                      (org-with-wide-buffer
                       (goto-char (marker-position target-mkr))
                       (org-transclusion-add-payload payload link plist copy))))))
              :else (apply-partially #'hyperdrive-org-transclusion-error-handler raw-link)))
          :else (apply-partially #'hyperdrive-org-transclusion-error-handler raw-link))))

;;;; Error handling

    (defun hyperdrive-org-transclusion-error-handler (url err)
      (let ((buf (get-buffer-create (format "*hyperdrive-org-transclusion-error <%s>" url))))
        (with-current-buffer buf
          (erase-buffer)
          (princ err (current-buffer)))
        (message "hyperdrive-org-transclusion: Unable to transclude content at <%s>.  Please open %S for details."
                 url buf)))))

;;;; Footer

(provide 'hyperdrive-org-transclusion)

;;; hyperdrive-org-transclusion.el ends here
