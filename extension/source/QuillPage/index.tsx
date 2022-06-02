import '../ContentScript';
import '../PageContentScript';

import ReactDOM from 'react-dom';

import QuillPage from './QuillPage';

import '../styles/index.scss';
import './styles.scss';

ReactDOM.render(<QuillPage />, document.getElementById('quill-page-root'));
