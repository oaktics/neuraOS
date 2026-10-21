import React, {Children, isValidElement, useState, type ReactElement, type ReactNode, type ComponentProps} from 'react';
import {Button as RadixButton, IconButton as RadixIconButton, Select as RadixSelect, Dialog, TextField, TextArea, Theme, Checkbox} from '@radix-ui/themes';
import {X} from 'lucide-react';
export {TextField, TextArea, Theme, Checkbox};

export function Button(props:Omit<ComponentProps<'button'>,'color'>){
  if(props.className?.includes('icon-button'))return <IconButton {...props}/>;
  if(!/(^| )(primary|secondary|danger-button)( |$)/.test(props.className??''))return <button {...props}/>;
  const danger=props.className?.includes('danger-button');
  return <RadixButton size="2" variant={props.className?.includes('secondary')?'surface':'solid'} color={danger?'red':props.className?.includes('secondary')?'gray':undefined} {...props} type={props.type??(props.onClick?'button':'submit')}/>;
}
export function IconButton(props:Omit<ComponentProps<'button'>,'color'>){return <RadixIconButton size="1" variant="ghost" color="gray" {...props} type={props.type??'button'}/>;}

export function Input(props:Omit<ComponentProps<'input'>,'size'|'color'|'value'|'defaultValue'|'type'> & {type?:ComponentProps<typeof TextField.Root>['type']|'file'|'checkbox';value?:string|number;defaultValue?:string|number}){
  const {type,...rest}=props;
  if(type==='file'||type==='checkbox')return <input type={type} {...rest}/>;
  return <TextField.Root size="2" variant="surface" type={type} {...rest}/>;
}

type OptionProps={value?:string;disabled?:boolean;children:ReactNode};
export function SelectOption(_props:OptionProps){return null;}
const EMPTY_VALUE='__neura_empty_selection__';
type SelectProps={value:string;onValueChange:(value:string)=>void;children:ReactNode;required?:boolean;disabled?:boolean;name?:string;id?:string;className?:string;'aria-label'?:string};
export function Select({value,onValueChange,children,required,disabled,name,id,className,...aria}:SelectProps){
  const options=Children.toArray(children).filter(isValidElement) as ReactElement<OptionProps>[];
  return <RadixSelect.Root value={value} onValueChange={next=>onValueChange(next===EMPTY_VALUE?'':next)} required={required} disabled={disabled} name={name} size="2">
    <RadixSelect.Trigger id={id} className={`ui-select ${className??''}`} variant="surface" placeholder={String(options.find(option=>option.props.value==='')?.props.children??'選択してください')} {...aria}/>
    <RadixSelect.Content variant="soft" color="gray" position="popper" sideOffset={5} className="ui-select-menu">
      {options.map(option=>{const key=option.props.value??String(option.props.children);return <RadixSelect.Item key={key} value={key||EMPTY_VALUE} disabled={option.props.disabled||(required&&key==='')}>{option.props.children}</RadixSelect.Item>;})}
    </RadixSelect.Content>
  </RadixSelect.Root>;
}
export function Modal({title,children,onClose,wide=false}:{title:string;children:ReactNode;onClose:()=>void;wide?:boolean}){
  const [previousFocus]=useState(()=>document.activeElement instanceof HTMLElement?document.activeElement:null);
  return <Dialog.Root open onOpenChange={open=>{if(!open)onClose();}}><Dialog.Content className="app-dialog" maxWidth={wide?'670px':'520px'} aria-describedby={undefined} onCloseAutoFocus={event=>{event.preventDefault();(previousFocus?.isConnected?previousFocus:document.querySelector<HTMLButtonElement>('.sidebar-create'))?.focus();}}>
    <div className="modal-heading"><Dialog.Title size="4" mb="0">{title}</Dialog.Title><Dialog.Close><IconButton aria-label="閉じる"><X size={18}/></IconButton></Dialog.Close></div>
    {children}
  </Dialog.Content></Dialog.Root>;
}
