use axum::{http::StatusCode,response::{IntoResponse,Response},Json};
use serde::Serialize;
#[derive(Debug,Clone,Serialize)]
pub struct ApiError {pub error:String,pub message:String,#[serde(skip)]pub status:u16}
impl ApiError {
 pub fn new(code:impl Into<String>,message:impl Into<String>,status:u16)->Self{Self{error:code.into(),message:message.into(),status}}
 pub fn storage()->Self{Self::new("storage_failed","保存処理に失敗しました。未確認操作は再送せず状態を確認してください。",503)}
}
impl std::fmt::Display for ApiError{fn fmt(&self,f:&mut std::fmt::Formatter<'_>)->std::fmt::Result{write!(f,"{}",self.error)}}
impl std::error::Error for ApiError{}
impl IntoResponse for ApiError{fn into_response(self)->Response{(StatusCode::from_u16(self.status).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR),Json(self)).into_response()}}
