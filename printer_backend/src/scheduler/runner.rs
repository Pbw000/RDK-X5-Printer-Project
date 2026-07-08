use std::num::NonZeroUsize;

use printers::{
    common::{
        base::{
            errors::PrintersError,
            job::{PrinterJobOptions, PrinterJobState},
            printer::Printer,
        },
        converters::{Converter},
    },
    get_default_printer, get_printer_by_name,
};

use crate::models::FileType;

use std::path::Path;

pub struct RunningPrintJob<'a> {
    printer: &'a Printer,
    job_id: u64,
}
impl<'a> RunningPrintJob<'a> {
    pub fn job_status(&self) -> PrinterJobState {
        self.printer
            .get_job_history()
            .iter()
            .find(|job| job.id == self.job_id)
            .map(|o| o.state.clone())
            .unwrap_or(PrinterJobState::UNKNOWN)
    }
    pub fn is_active(&self) -> bool {
        self.printer
            .get_active_jobs()
            .iter()
            .find(|job| job.id == self.job_id)
            .map(|state| {
                matches!(
                    state.state,
                    PrinterJobState::PENDING | PrinterJobState::PROCESSING
                )
            })
            .unwrap_or(false)
    }
    pub fn cancel(&self) -> Result<(), PrintersError> {
        self.printer.cancel_job(self.job_id)
    }
    pub async fn poll_wait(&self) {
        let mut poll_count: u32 = 0;
        loop {
            let active = self.is_active();
            let status = self.job_status();
            poll_count += 1;
            if poll_count % 5 == 1 || !active {
                tracing::info!(
                    job_id = self.job_id,
                    poll_count = poll_count,
                    is_active = active,
                    job_state = ?status,
                    "poll_wait: checking print job status"
                );
            }
            if !active {
                break;
            }
            const SLEEP_DURATION: std::time::Duration = std::time::Duration::from_millis(1000);
            tokio::time::sleep(SLEEP_DURATION).await;
        }
    }

    pub fn pause(&self) -> Result<(), PrintersError> {
        self.printer.pause_job(self.job_id)
    }
    pub fn resume(&self) -> Result<(), PrintersError> {
        self.printer.resume_job(self.job_id)
    }
}
pub struct PrinterExecutor {
    printer: Printer,
}

impl std::fmt::Display for PrinterExecutor {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{:?}", self.printer)
    }
}

impl PrinterExecutor {
    pub fn name(&self) -> &str {
        &self.printer.name
    }
    pub fn default() -> Option<Self> {
        get_default_printer().map(|i| Self { printer: i })
    }
    pub fn new(printer_name: &str) -> Option<Self> {
        get_printer_by_name(printer_name).map(|i| Self { printer: i })
    }
    pub fn print_pdf<'a>(&'a self, path: &str) -> Result<RunningPrintJob<'a>, PrintersError> {
        let job_id = self.printer.print_file(
            path,
            PrinterJobOptions {
                name: Some(path.split('/').last().unwrap_or(path)),
                raw_properties: &[],
                converter: Converter::None,
            },
        )?;
        Ok(RunningPrintJob {
            printer: &self.printer,
            job_id,
        })
    }
    pub fn print_many_pdf<'a>(
        &'a self,
        path: &str,
        copy: NonZeroUsize,
    ) -> Result<RunningPrintJob<'a>, PrintersError> {
        let job_id = self.printer.print_file(
            path,
            PrinterJobOptions {
                name: Some(path.split('/').last().unwrap_or(path)),
                raw_properties: &[("copies", &copy.to_string())],
                converter: Converter::None,
            },
        )?;
        Ok(RunningPrintJob {
            printer: &self.printer,
            job_id,
        })
    }

    /// Print a plain-text file (raw passthrough to printer).
    pub fn print_txt<'a>(&'a self, path: &str) -> Result<RunningPrintJob<'a>, PrintersError> {
        let job_id = self.printer.print_file(
            path,
            PrinterJobOptions {
                name: Some(path.split('/').last().unwrap_or(path)),
                raw_properties: &[],
                converter: Converter::None,
            },
        )?;
        Ok(RunningPrintJob {
            printer: &self.printer,
            job_id,
        })
    }

    /// Print multiple copies of a plain-text file.
    pub fn print_many_txt<'a>(
        &'a self,
        path: &str,
        copy: NonZeroUsize,
    ) -> Result<RunningPrintJob<'a>, PrintersError> {
        let job_id = self.printer.print_file(
            path,
            PrinterJobOptions {
                name: Some(path.split('/').last().unwrap_or(path)),
                raw_properties: &[("copies", &copy.to_string())],
                converter: Converter::None,
            },
        )?;
        Ok(RunningPrintJob {
            printer: &self.printer,
            job_id,
        })
    }

    /// Print an image file (JPEG / PNG).
    /// Uses ps2write: Ghostscript auto-detects the image format from stdin,
    /// rasterizes it, and outputs PostScript that the printer can consume.
    /// png16m is an OUTPUT device and cannot read image bytes as input.
    pub fn print_image<'a>(&'a self, path: &str) -> Result<RunningPrintJob<'a>, PrintersError> {
        let job_id = self.printer.print_file(
            path,
            PrinterJobOptions {
                name: Some(path.split('/').last().unwrap_or(path)),
                raw_properties: &[],
                converter: Converter::None,
            },
        )?;
        Ok(RunningPrintJob {
            printer: &self.printer,
            job_id,
        })
    }

    /// Print multiple copies of an image file.
    pub fn print_many_image<'a>(
        &'a self,
        path: &str,
        copy: NonZeroUsize,
    ) -> Result<RunningPrintJob<'a>, PrintersError> {
        let job_id = self.printer.print_file(
            path,
            PrinterJobOptions {
                name: Some(path.split('/').last().unwrap_or(path)),
                raw_properties: &[("copies", &copy.to_string())],
                converter: Converter::None,
            },
        )?;
        Ok(RunningPrintJob {
            printer: &self.printer,
            job_id,
        })
    }

    /// Dispatch print by detected file type.
    /// Picks the correct converter automatically:
    ///   - PDF  → Ghostscript ps2write
    ///   - JPEG/PNG → Ghostscript png16m
    ///   - TXT  → raw passthrough (Converter::None)
    pub fn print_by_type<'a>(
        &'a self,
        path: &str,
        file_type: FileType,
    ) -> Result<RunningPrintJob<'a>, PrintersError> {
        match file_type {
            FileType::Pdf => self.print_pdf(path),
            FileType::Jpeg | FileType::Png => self.print_image(path),
            FileType::Txt => self.print_txt(path),
        }
    }

    /// Auto-detect file type from the path extension and print accordingly.
    /// Convenience wrapper around `print_by_type`.
    pub fn print_by_extension<'a>(
        &'a self,
        path: &str,
    ) -> Result<RunningPrintJob<'a>, PrintersError> {
        let file_type = Self::detect_file_type(path)?;
        self.print_by_type(path, file_type)
    }

    /// Dispatch multi-copy print by detected file type.
    pub fn print_many_by_type<'a>(
        &'a self,
        path: &str,
        file_type: FileType,
        copy: NonZeroUsize,
    ) -> Result<RunningPrintJob<'a>, PrintersError> {
        match file_type {
            FileType::Pdf => self.print_many_pdf(path, copy),
            FileType::Jpeg | FileType::Png => self.print_many_image(path, copy),
            FileType::Txt => self.print_many_txt(path, copy),
        }
    }

    /// Auto-detect file type from the path extension and print multiple copies.
    pub fn print_many_by_extension<'a>(
        &'a self,
        path: &str,
        copy: NonZeroUsize,
    ) -> Result<RunningPrintJob<'a>, PrintersError> {
        let file_type = Self::detect_file_type(path)?;
        self.print_many_by_type(path, file_type, copy)
    }

    /// Detect `FileType` from a file path's extension.
    fn detect_file_type(path: &str) -> Result<FileType, PrintersError> {
        let ext = Path::new(path)
            .extension()
            .and_then(|e| e.to_str())
            .map(|s| s.to_ascii_lowercase());
        match ext.as_deref().and_then(FileType::from_extension) {
            Some(ft) if ft.is_printable() => Ok(ft),
            Some(ft) => Err(PrintersError::file_error(format!(
                "File type {:?} is not printable",
                ft
            ))),
            None => Err(PrintersError::file_error(format!(
                "Cannot detect file type from extension: {:?}",
                ext.unwrap_or_default()
            ))),
        }
    }
}
